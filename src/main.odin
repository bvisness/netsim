package main

import "core:container/queue"
import "core:fmt"
import "core:intrinsics"
import "core:math"
import "core:math/rand"
import "core:mem"
import "core:runtime"
import "core:slice"
import "core:strings"
import "vendor:wasm/js"

global_arena := Arena{}
temp_arena := Arena{}

wasmContext := runtime.default_context()

nodes : [dynamic]Node
conns : [dynamic]Connection
exiting_packets : [dynamic]Packet

nodes_by_name : map[string]^Node

t: f32 = 0
min_width   : f32 = 10000
min_height  : f32 = 10000
max_width   : f32 = 0
max_height  : f32 = 0
text_height : f32 = 16

bg_color      := Vec3{}
text_color    := Vec3{}
text_color2   := Vec3{}
button_color  := Vec3{}
line_color    := Vec3{}
graph_color   := Vec3{}
node_color    := Vec3{}
toolbar_color := Vec3{}

default_font   := `-apple-system,BlinkMacSystemFont,segoe ui,Helvetica,Arial,sans-serif,apple color emoji,segoe ui emoji,segoe ui symbol`
monospace_font := `monospace`
icon_font      := `FontAwesome`

scale        : f32 = 1
last_mouse_pos := Vec2{}
mouse_pos      := Vec2{}
clicked_pos    := Vec2{}
pan            := Vec2{}
scroll_velocity: f32 = 0
is_mouse_down := false
clicked := false

node_selected := -1

pad_size       : f32 = 40
toolbar_height : f32 = 40
buffer_size    : int = 15
history_size   : int = 50
running := false

TICK_INTERVAL_BASE :: 0.7
TICK_ANIM_DURATION_BASE :: 0.7
NEW_ANIM_DURATION_BASE :: 0.3
DONE_ANIM_DURATION_BASE :: 0.8
DROPPED_ANIM_DURATION :: 1.2
tones := []f32{ 392, 440, 493.88, 523.25, 587.33, 659.25, 739.99 }

timescale: f32
tick_interval: f32
tick_anim_duration: f32
new_anim_duration: f32
done_anim_duration: f32

set_timescale :: proc(new_timescale: f32) {
	timescale = new_timescale
	tick_interval = TICK_INTERVAL_BASE * timescale
	tick_anim_duration = TICK_ANIM_DURATION_BASE * timescale
	new_anim_duration = NEW_ANIM_DURATION_BASE * timescale
	done_anim_duration = DONE_ANIM_DURATION_BASE * timescale
}

@export
set_color_mode :: proc "contextless" (is_dark: bool) {
	if is_dark {
		bg_color      = Vec3{15, 15, 15}
		text_color    = Vec3{255, 255, 255}
		text_color2   = Vec3{180, 180, 180}
		button_color  = Vec3{40, 40, 40}
		line_color    = Vec3{120, 120, 120}
		node_color    = Vec3{180, 180, 180}
		graph_color   = Vec3{180, 180, 180}
		toolbar_color = Vec3{120, 120, 120}
	} else {
		bg_color      = Vec3{254, 252, 248}
		text_color    = Vec3{0, 0, 0}
		text_color2   = Vec3{80, 80, 80}
		button_color  = Vec3{161, 139, 124}
		line_color    = Vec3{219, 211, 205}
		node_color    = Vec3{129, 100, 80}
		graph_color   = Vec3{69, 49, 34}
		toolbar_color = Vec3{219, 211, 205}
	}
}

main :: proc() {
	global_data, _ := js.page_alloc(100)
	temp_data, _ := js.page_alloc(100)
    arena_init(&global_arena, global_data)
    arena_init(&temp_arena, temp_data)

    wasmContext.allocator = arena_allocator(&global_arena)
    wasmContext.temp_allocator = arena_allocator(&temp_arena)

    context = wasmContext

	set_timescale(0.4)

	nodes = make([dynamic]Node)
	conns = make([dynamic]Connection)
	exiting_packets = make([dynamic]Packet)

	if ok := load_config(net_config, &nodes, &conns); !ok {
		fmt.printf("Failed to load config!\n")
		trap()
	}

	nodes_by_name = make(map[string]^Node)
	for n in &nodes {
		nodes_by_name[n.name] = &n
	}

	// nasty padding adjustments ahoy
	for i := 0; i < len(nodes); i += 1 {
		node := &nodes[i]

		if node.pos.x < min_width {
			min_width = node.pos.x
		}

		if node.pos.y < min_height {
			min_height = node.pos.y
		}
	}
	for i := 0; i < len(nodes); i += 1 {
		node := &nodes[i]

		node.pos.x = (node.pos.x - min_width)
		node.pos.y = (node.pos.y - min_height)

		if node.pos.x > max_width {
			max_width = node.pos.x
		}

		if node.pos.y > max_height {
			max_height = node.pos.y
		}
	}
	max_width += node_size + pad_size
	max_height += node_size + pad_size
	pan = Vec2{pad_size, pad_size + toolbar_height}
}

tick :: proc() {	
	defer last_tick_t = t
	defer tick_count += 1

	PacketSend :: struct {
		packet: Packet,
		src: ^Node,
		dst: ^Node,
	}
	packet_sends := make([dynamic]PacketSend, context.temp_allocator)

	NodeAndID :: struct {
		n: ^Node,
		id: int,
	}
	nodes_shuffled := make([]NodeAndID, len(nodes))
	for node, node_id in &nodes {
		nodes_shuffled[node_id] = NodeAndID{n = &node, id = node_id}
	}
	rand.shuffle(nodes_shuffled)
	for entry in nodes_shuffled {
		node := entry.n
		node_id := entry.id

		// Update packet animation data (for everything but the top one, which will be popped)
		for i := 1; i < queue.len(node.buffer); i += 1 {
			packet := queue.get_ptr(&node.buffer, i)
			packet.anim = PacketAnimation.None
			packet.src_node = node
			packet.src_bufid = i
			packet.dst_node = node
			packet.dst_bufid = i - 1

			packet.tick_life += 1
		}

		node.old_received = node.received
		node.old_sent     = node.sent
		node.old_dropped  = node.dropped

		// Get average packet lifetime for the node
		average_packet_ticks : u32 = 0
		if queue.len(node.buffer) > 0 {
			for i := 0; i < queue.len(node.buffer); i += 1 {
				packet := queue.get_ptr(&node.buffer, i)
				average_packet_ticks += packet.tick_life
			}

			average_packet_ticks /= u32(queue.len(node.buffer))
		}
		for ; queue.len(node.avg_tick_history) >= history_size; {
			queue.pop_front(&node.avg_tick_history)
		}
		queue.push_back(&node.avg_tick_history, average_packet_ticks)
 
		nextpacket:
		for i := 0; i < node.packets_per_tick; i += 1 {
			// Try to send
			packet, ok := queue.pop_front_safe(&node.buffer)
			if !ok {
				break
			}

			// Handle packets destined for this node
			is_for_me := false
			for iface in node.interfaces {
				if packet.dst_ip == iface.ip {
					is_for_me = true
					break
				}
			}
			if is_for_me {
				// fmt.printf("Node %d: thank you for the packet in these trying times\n", node_id)

				handle_packet(node, packet)

				packet.anim = PacketAnimation.Delivered
				packet.dst_node = node
				packet.delivered_t = t
				append(&exiting_packets, packet)
				continue
			}

			// fmt.printf("Checking node %s\n", node.name)
			// Uh, route it somewhere else
			for rule in node.routing_rules {
				masked_dest := packet.dst_ip & rule.subnet_mask
				// fmt.printf("%s & %s (%s) == %s?\n", ip_to_str(packet.dst_ip), ip_to_str(rule.subnet_mask), ip_to_str(masked_dest), ip_to_str(rule.ip))
				if masked_dest == rule.ip {
					if dst_node, ok := get_connected_node(node_id, rule.interface_id); ok {
						packet.ttl += 1
						append(&packet_sends, PacketSend{
							packet = packet,
							src = node,
							dst = dst_node,
						})
						// fmt.printf("Node %d: here have packet!!\n", node_id)
					} else {
						// fmt.printf("Node %s [%s]: bad routing rule! discarding packet.\n", node.name, ip_to_str(node.interfaces[0].ip))
						// fmt.printf("%s -> %s\n", ip_to_str(packet.src_ip), ip_to_str(packet.dst_ip))
						node.dropped += 1
						drop_packet(packet)
						running = false
					}
					continue nextpacket
				}
			}

			// the hell is this packet
			// fmt.printf("Node %s [%s]: the hell is this packet? discarding\n", node.name, ip_to_str(node.interfaces[0].ip))
			// fmt.printf("%s -> %s\n", ip_to_str(packet.src_ip), ip_to_str(packet.dst_ip))
			node.dropped += 1
			drop_packet(packet)
		}
	}

	for send in packet_sends {
		packet := send.packet
		packet.anim = PacketAnimation.None
		packet.src_node = send.src
		packet.src_bufid = 0 // top of the buffer
		packet.dst_node = send.dst
		packet.dst_bufid = queue.len(send.dst.buffer)

		if queue.len(send.dst.buffer) >= buffer_size {
			// fmt.printf("Buffer full, packet dropped\n")
			packet.dst_node.dropped += 1
			drop_packet(packet, true)
			continue
		}

		send.src.sent += 1
		send.dst.received += 1
		queue.push_back(&send.dst.buffer, packet)
	}

	// Update stat histories
	for node in &nodes {
		if queue.len(node.avg_recv_history) >= history_size {
			queue.pop_front(&node.avg_recv_history)
		}
		if queue.len(node.avg_sent_history) >= history_size {
			queue.pop_front(&node.avg_sent_history)
		}
		if queue.len(node.avg_drop_history) >= history_size {
			queue.pop_front(&node.avg_drop_history)
		}

		queue.push_back(&node.avg_recv_history, u32(node.received - node.old_received))
		queue.push_back(&node.avg_sent_history, u32(node.sent - node.old_sent))
		queue.push_back(&node.avg_drop_history, u32(node.dropped - node.old_dropped))
	}

	// And extra fun stuff we do on each tick for testing:

	// Generate random packets, huzzah
	// if tick_count % 3 == 0 {
	// 	for i := 0; i < 10; i += 1 {
	// 		generate_random_packet()
	// 	}
	// }

	if tick_count % 1 == 0 {
		dst_ip := nodes_by_name["discord_1"].interfaces[0].ip
		if sess, already_connected := get_tcp_session(nodes_by_name["me"], dst_ip); !already_connected {
			sess, ok := new_tcp_session(nodes_by_name["me"], dst_ip)
			assert(ok)

			// HACK: Open up destination for listening
			dst := nodes_by_name["discord_1"]
			dst.listening = true

			iss := tcp_initial_sequence_num()

			hello_discord := Packet{
				dst_ip = dst_ip,
				protocol = PacketProtocol.TCP,
				tcp = PacketTcp{
					sequence_number = iss,
					control_flags = TCP_SYN,
				},
				color = COLOR_SYN,
			}
			send_packet(nodes_by_name["me"], hello_discord)

			sess.initial_send_seq_num = iss
			sess.send_unacknowledged = iss
			sess.send_next = iss + 1

			sess.state = TcpState.SynSent
		} else {
			if sess.state == TcpState.Established {
				// send le data
				p := Packet{
					dst_ip = dst_ip,
					data = "Hello!",
					protocol = PacketProtocol.TCP,
					tcp = PacketTcp{
						// sequence_number = ???
						ack_number = sess.receive_next,
						control_flags = TCP_ACK,
						window = 10, // excellent choice of window
					},
				}
				send_packet(nodes_by_name["me"], p)
				sess.send_next += u32(len(p.data))
			}
		}
	}
}

drop_packet :: proc(packet: Packet, drop_at_dst: bool = false) {
	packet := packet
	packet.anim = PacketAnimation.Dropped
	packet.dropped_t = t
	if !drop_at_dst {
		packet.velocity = Vec2{-35, 0}
	}
	packet.drop_at_dst = drop_at_dst
	append(&exiting_packets, packet)
}

get_connected_node :: proc(my_node_id, my_interface_id: int) -> (^Node, bool) {
	for _, conn_id in conns {
		conn := &conns[conn_id]
		matches_src := conn.src_id.node_id == my_node_id && conn.src_id.interface_id == my_interface_id
		matches_dst := conn.dst_id.node_id == my_node_id && conn.dst_id.interface_id == my_interface_id
		
		other: ConnectionID
		if matches_src {
			other = conn.dst_id
		} else if matches_dst {
			other = conn.src_id
		} else {
			continue
		}

		return &nodes[other.node_id], true
	}

	return nil, false
}

tick_count := 0
last_tick_t := t

was_mouse_down := false

@export
frame :: proc "contextless" (width, height: f32, dt: f32) -> bool {
    context = wasmContext
	defer free_all(context.temp_allocator)

	if !was_mouse_down && is_mouse_down {
		clicked = true
		clicked_pos = mouse_pos
	}
	defer was_mouse_down = is_mouse_down
	defer clicked = false

    t += dt

	// compute scroll
	scale *= 1 + (0.05 * scroll_velocity * dt)
	if scale < 0.1 {
		scale = 0.1
	} else if scale > 1.5 {
		scale = 1.5
	}
	scroll_velocity = 0

	// compute pan
	pan_velocity := Vec2{}
	if is_mouse_down {
		if clicked_pos.x < max_width && clicked_pos.x > 0 && clicked_pos.y < height && clicked_pos.y > toolbar_height {
			pan_velocity.x = mouse_pos.x - last_mouse_pos.x
			pan_velocity.y = mouse_pos.y - last_mouse_pos.y
		}
		last_mouse_pos = mouse_pos
	}
	pan += 3 * pan_velocity

	if running && t - last_tick_t >= tick_interval {
		tick()
	}


    canvas_clear()
    draw_rect(rect(0, 0, width, height), 0, bg_color)

	// Render graph view

	// render lines
	for conn in conns {
		node_a := nodes[conn.src_id.node_id]
		node_b := nodes[conn.dst_id.node_id]
		scaled_line(node_a.pos.x + (node_size / 2), node_a.pos.y + (node_size / 2), node_b.pos.x + (node_size / 2), node_b.pos.y + (node_size / 2), line_color.x, line_color.y, line_color.z, 255, 3)
	}

	// render nodes
	for node in &nodes {
    	scaled_rect(node.pos.x, node.pos.y, node_size, node_size, 5, node_color.x, node_color.y, node_color.z, 255)

		// Draw label
		scaled_text(node.name, node.pos.x, node.pos.y - 16, default_font, text_color.x, text_color.y, text_color.z, 255)

		// Draw ???
		// if queue.len(node.buffer) > 0 {
		// 	pos := Vec2{node.pos.x + ((node_size / 2) - (packet_size / 2)), node.pos.y + ((node_size / 2) - (packet_size / 2))}
		// 	color : f32 = ((-math.cos_f32(t) + 1) / 2) * 255

		// 	scaled_rect(pos.x, pos.y, packet_size, packet_size, packet_size / 2, int(color), 100, 100, 255)
		// }

		// Draw node packets
		for i := 0; i < queue.len(node.buffer); i += 1 {
			packet := queue.get_ptr(&node.buffer, i)
			draw_packet_in_transit(packet)
		}
	}

	// Draw exiting packets
	dead_packets := make([dynamic]int, context.temp_allocator)
	for packet, i in &exiting_packets {
		#partial switch packet.anim {
		case .Delivered:
			anim_t := (t - packet.delivered_t) / done_anim_duration
			pos := math.lerp(packet.pos, packet.dst_node.pos + Vec2{node_size/2, node_size/2}, ease_in_back(anim_t))
			size := math.lerp(packet_size_in_buffer, packet_size, ease_in(anim_t))
			alpha := math.lerp(f32(255), f32(0), ease_linear(anim_t, 0.9, 1))
			scaled_circle(pos.x, pos.y, size, packet.color.x, packet.color.y, packet.color.z, alpha)

			if anim_t > 1 {
				append(&dead_packets, i)
			}
		case .Dropped:
			pos_t := (t - packet.dropped_t) / tick_anim_duration
			if packet.drop_at_dst && !packet.initialized_drop_at_dst && pos_t < 0.8 {
				draw_packet_in_transit(&packet)
			} else {
				// initialize mid-stream drop animation
				if packet.drop_at_dst && !packet.initialized_drop_at_dst {
					packet.velocity = (packet.pos - packet.last_pos) / dt
					packet.velocity = packet.velocity * -0.2 // bounce, lol
					packet.dropped_t = t
					packet.initialized_drop_at_dst = true

					idx := rand_int(0, len(tones) - 1)
					play_tone(tones[idx])
				}

				packet.velocity += Vec2{0, 180} * dt
				packet.pos += packet.velocity * dt
				anim_t := (t - packet.dropped_t) / DROPPED_ANIM_DURATION
				alpha := math.lerp(f32(255), f32(0), anim_t)
				scaled_circle(packet.pos.x, packet.pos.y, packet_size_in_buffer, packet.color.x, packet.color.y, packet.color.z, alpha)

				if anim_t > 1 {
					append(&dead_packets, i)
				}
			}
		}
	}

	// Render toolbar
    draw_rect(rect(0, 0, width, toolbar_height), 0, toolbar_color)

	// Render menu view
    draw_rect(rect(max_width + pad_size, toolbar_height, width, height), 0, bg_color)

	// draw menu border
	draw_line(Vec2{max_width + pad_size, toolbar_height}, Vec2{max_width + pad_size, height}, 3, line_color)

	menu_offset := max_width + (pad_size * 2)

	// check intersections
	for node, idx in &nodes {
		if clicked && pt_in_rect(mouse_pos, Rect{(node.pos * scale) + pan, Vec2{node_size * scale, node_size * scale}}) {
			node_selected = idx
			break
		}
	}

	if node_selected != -1 {
		inspect_node := nodes[node_selected]

		y: f32 = 0
		next_line := proc(y: ^f32) -> f32 {
			res := y^
			y^ += text_height + 4
			return res
		}

		y = pad_size + toolbar_height
		draw_text("Node Inspector", Vec2{menu_offset, next_line(&y)}, 1, default_font, text_color)
		draw_text(fmt.tprintf("Name: %s", inspect_node.name), Vec2{menu_offset, next_line(&y)}, 1, monospace_font, text_color2)
		draw_text(fmt.tprintf("Sent: %d", inspect_node.sent), Vec2{menu_offset, next_line(&y)}, 1, monospace_font, text_color2)
		draw_text(fmt.tprintf("Received: %d", inspect_node.received), Vec2{menu_offset, next_line(&y)}, 1, monospace_font, text_color2)
		draw_text(fmt.tprintf("Dropped: %d", inspect_node.dropped), Vec2{menu_offset, next_line(&y)}, 1, monospace_font, text_color2)

		buffer_used := min(buffer_size, queue.len(inspect_node.buffer))
		draw_text(fmt.tprintf("Buffer used: %d/%d", buffer_used, buffer_size), Vec2{menu_offset, next_line(&y)}, 1, monospace_font, text_color2)

		average_packet_ticks : u32 = 0
		average_packet_ttl   : u32 = 0
		node_packet_count := queue.len(inspect_node.buffer)

		if node_packet_count > 0 {
			for i := 0; i < node_packet_count; i += 1 {
				packet := queue.get_ptr(&inspect_node.buffer, i)
				average_packet_ticks += packet.tick_life
				average_packet_ttl += packet.ttl
			}
			average_packet_ticks /= u32(node_packet_count)
			average_packet_ttl /= u32(node_packet_count)
		}

		draw_text(fmt.tprintf("Average Packet Ticks: %d", average_packet_ticks), Vec2{menu_offset, next_line(&y)}, 1, monospace_font, text_color2)
		draw_text(fmt.tprintf("Average Packet TTL: %d", average_packet_ttl), Vec2{menu_offset, next_line(&y)}, 1, monospace_font, text_color2)

		// render history graph
		graph_top := next_line(&y) + pad_size
		graph_size : f32 = 200
		graph_gap : f32 = (text_height + 4) * 2
		draw_graph("Avg. Packets Sent Over Time", &inspect_node.avg_sent_history, menu_offset, graph_top, graph_size)
		draw_graph("Avg. Packets Received Over Time", &inspect_node.avg_recv_history, menu_offset + graph_size + graph_gap, graph_top, graph_size)
		draw_graph("Avg. Packets Dropped Over Time", &inspect_node.avg_drop_history, menu_offset, graph_top + graph_size + graph_gap, graph_size)
		draw_graph("Avg. Packet Ticks Over Time", &inspect_node.avg_tick_history, menu_offset + graph_size + graph_gap, graph_top + graph_size + graph_gap, graph_size)

		// render logs and debug info
		{
			logs_left: f32 = menu_offset + 500

			y = pad_size + toolbar_height
			draw_text("Connections:", Vec2{logs_left, next_line(&y)}, 1, default_font, text_color)
			for sess in inspect_node.tcp_sessions {
				if sess.ip == 0 {
					continue
				}
				draw_text(fmt.tprintf("%s: %v", ip_to_str(sess.ip), sess.state), Vec2{logs_left, next_line(&y)}, 1, monospace_font, text_color2)
				draw_text(fmt.tprintf("  State: %v", sess.state), Vec2{logs_left, next_line(&y)}, 1, monospace_font, text_color2)
				draw_text(fmt.tprintf("  SND.UNA: %v", sess.send_unacknowledged), Vec2{logs_left, next_line(&y)}, 1, monospace_font, text_color2)
				draw_text(fmt.tprintf("  SND.NXT: %v", sess.send_next), Vec2{logs_left, next_line(&y)}, 1, monospace_font, text_color2)
				draw_text(fmt.tprintf("  SND.WND: %v", sess.send_window), Vec2{logs_left, next_line(&y)}, 1, monospace_font, text_color2)
				draw_text(fmt.tprintf("  ISS: %v", sess.initial_send_seq_num), Vec2{logs_left, next_line(&y)}, 1, monospace_font, text_color2)
				draw_text(fmt.tprintf("  RCV.NXT: %v", sess.receive_next), Vec2{logs_left, next_line(&y)}, 1, monospace_font, text_color2)
				draw_text(fmt.tprintf("  RCV.WND: %v", sess.receive_window), Vec2{logs_left, next_line(&y)}, 1, monospace_font, text_color2)
				draw_text(fmt.tprintf("  IRS: %v", sess.initial_receive_seq_num), Vec2{logs_left, next_line(&y)}, 1, monospace_font, text_color2)
			}

			next_line(&y)

			log_lines := int((height - (pad_size * 2) - y) / (text_height + 4))
			draw_text("Logs:", Vec2{logs_left, next_line(&y)}, 1, default_font, text_color)
			if len(inspect_node.logs) > log_lines {
				draw_text("...", Vec2{logs_left, next_line(&y)}, 1, monospace_font, text_color2)
			}
			for msg in inspect_node.logs[max(0, len(inspect_node.logs)-log_lines):] {
				draw_text(msg, Vec2{logs_left, next_line(&y)}, 1, monospace_font, text_color2)
			}
		}
	}

	top_pad := toolbar_height + 20
	draw_circle(Vec2{20 + packet_size, top_pad+packet_size+20*0}, packet_size, COLOR_SYN)
	draw_circle(Vec2{20 + packet_size, top_pad+packet_size+20*1}, packet_size, COLOR_ACK)
	draw_circle(Vec2{20 + packet_size, top_pad+packet_size+20*2}, packet_size, COLOR_SYNACK)
	draw_circle(Vec2{20 + packet_size, top_pad+packet_size+20*3}, packet_size, COLOR_RST)
	draw_text("SYN",    Vec2{38, top_pad+20*0}, 1, default_font, text_color)
	draw_text("ACK",    Vec2{38, top_pad+20*1}, 1, default_font, text_color)
	draw_text("SYNACK", Vec2{38, top_pad+20*2}, 1, default_font, text_color)
	draw_text("RST",    Vec2{38, top_pad+20*3}, 1, default_font, text_color)

	edge_pad : f32 = 10
	button_height : f32 = 30
	button_width  : f32 = 30
	if button(rect(edge_pad, (toolbar_height / 2) - (button_height / 2), button_width, button_height), running ? "\uf04c" : "\uf04b", icon_font) {
		running = !running
	}
	if !running {
		if button(rect(edge_pad + button_width + 8, (toolbar_height / 2) - (button_height / 2), button_width, button_height), "\uf051", icon_font) {
			tick()
		}
	}

	remove_packets(&exiting_packets, dead_packets[:])

    return true
}

generate_random_packet :: proc() {
	src_id := int(rand.int31()) % len(nodes)
	dst_id := int(rand.int31()) % len(nodes)

	if src_id == dst_id {
		return
	}

	if queue.len(nodes[src_id].buffer) >= buffer_size {
		return
	}

	send_packet(&nodes[src_id], Packet{
		src_ip = nodes[src_id].interfaces[0].ip,
		dst_ip = nodes[dst_id].interfaces[0].ip,
		color = Vec3{f32(rand_int(80, 230)), f32(rand_int(80, 230)), f32(rand_int(80, 230))},
	})
}

draw_packet_in_transit :: proc(packet: ^Packet) {
	pos_t := clamp(0, 1, (t - last_tick_t) / tick_anim_duration)
			
	src_pos := pos_in_buffer(packet.src_node, packet.src_bufid)
	dst_pos := pos_in_buffer(packet.dst_node, packet.dst_bufid)
	pos_direct := math.lerp(src_pos, dst_pos, ease_in_out(pos_t))

	pos := pos_direct
	size := packet_size_in_buffer

	if packet.src_node != packet.dst_node {
		pos_along_connection := math.lerp(packet.src_node.pos + Vec2{node_size/2, node_size/2}, packet.dst_node.pos + Vec2{node_size/2, node_size/2}, ease_in_out(pos_t))
		pos = math.lerp(pos_direct, pos_along_connection, bounce_parabolic(pos_t) * 0.4)
		size = math.lerp(packet_size_in_buffer, packet_size, bounce_parabolic(pos_t))
	}

	if packet.anim == PacketAnimation.New {
		size_t := clamp(0, 1, (t - packet.created_t) / new_anim_duration)
		size = math.lerp(f32(0), packet_size_in_buffer, ease_in_out(size_t))
	}

	scaled_circle(pos.x, pos.y, size, packet.color.x, packet.color.y, packet.color.z, 255)
	packet.last_pos = packet.pos
	packet.pos = pos
}

draw_graph :: proc(header: string, history: ^queue.Queue(u32), x, y, size: f32) {
	line_width : f32 = 1

	text_width := measure_text(header, 1, default_font)
	center_offset := (size / 2) - (text_width / 2)
	draw_text(header, Vec2{x + center_offset, y}, 1, default_font, text_color2)

	graph_top := y + text_height + 4
	draw_line(Vec2{x, graph_top}, Vec2{x + size, graph_top}, 3, line_color)
	draw_line(Vec2{x, graph_top}, Vec2{x, graph_top + size}, 3, line_color)
	draw_line(Vec2{x + size, graph_top}, Vec2{x + size, graph_top + size}, 3, line_color)
	draw_line(Vec2{x, graph_top + size}, Vec2{x + size, graph_top + size}, 3, line_color)

	max_val : u32 = 0
	min_val : u32 = 100000
	for i := 0; i < queue.len(history^); i += 1 {
		entry := queue.get(history, i)
		max_val = max(max_val, entry)
		min_val = min(min_val, entry)
	}
	max_range := max_val - min_val

	graph_edge_pad : f32 = 15
	graph_y_bounds := size - (graph_edge_pad * 2)
	graph_x_bounds := size - graph_edge_pad

	last_x : f32 = 0
	last_y : f32 = 0
	for i := 0; i < queue.len(history^); i += 1 {
		entry := queue.get(history, i)

		point_x_offset : f32 = 0
		if queue.len(history^) != 0 {
			point_x_offset = f32(i) * (graph_x_bounds / f32(queue.len(history^)))
		}

		point_y_offset : f32 = 0
		if max_range != 0 {
			point_y_offset = f32(entry - min_val) * (graph_y_bounds / f32(max_range))
		}

		point_x := x + point_x_offset + (graph_edge_pad / 2)
		point_y := graph_top + size - point_y_offset - graph_edge_pad

		if queue.len(history^) > 1  && i > 0 {
			canvas_line(last_x, last_y, point_x, point_y, graph_color.x, graph_color.y, graph_color.z, 255, line_width)
		}

		last_x = point_x
		last_y = point_y
	}
}

remove_packets :: proc(packets: ^[dynamic]Packet, indexes: []int) {
	for i := len(indexes)-1; i >= 0; i -= 1 {
		ordered_remove(packets, indexes[i])
	}
}

pt_in_rect :: proc(pt: Vec2, box: Rect) -> bool {
	x1 := box.pos.x
	y1 := box.pos.y
	x2 := box.pos.x + box.size.x
	y2 := box.pos.y + box.size.y

	return x1 <= pt.x && pt.x <= x2 && y1 <= pt.y && pt.y <= y2
}

button :: proc(rect: Rect, text: string, font: string) -> bool {
	draw_rect(rect, 2, button_color)
	text_width := measure_text(text, 1, font)
	font_height : f32 = 16
	draw_text(text, Vec2{rect.pos.x + rect.size.x/2 - text_width/2, rect.pos.y+(font_height / 2)}, 1, font, text_color)
	if clicked && pt_in_rect(mouse_pos, rect) {
		return true
	}
	return false
}
