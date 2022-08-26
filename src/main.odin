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
import "core:strconv"
import "vendor:wasm/js"

global_arena := Arena{}
temp_arena := Arena{}

wasmContext := runtime.default_context()

nodes : [dynamic]Node
conns : [dynamic]Connection
exiting_packets : [dynamic]Packet
inputs: [dynamic]InputField

nodes_by_name : map[string]^Node

t           : f32
last_tick_t : f32
tick_count  : int
frame_count : int

min_width  : f32
min_height : f32
max_width  : f32
max_height : f32

bg_color      := Vec3{}
bg_color2     := Vec3{}
text_color    := Vec3{}
text_color2   := Vec3{}
text_color3   := Vec3{}
button_color  := Vec3{}
button_color2 := Vec3{}
line_color    := Vec3{}
outline_color := Vec3{}
graph_color   := Vec3{}
node_color    := Vec3{}
node_color2   := Vec3{}
toolbar_color := Vec3{}

default_font   := `-apple-system,BlinkMacSystemFont,segoe ui,Helvetica,Arial,sans-serif,apple color emoji,segoe ui emoji,segoe ui symbol`
monospace_font := `monospace`
icon_font      := `FontAwesome`

scale          : f32

last_mouse_pos := Vec2{}
mouse_pos      := Vec2{}
clicked_pos    := Vec2{}
pan            := Vec2{}
scroll_velocity: f32 = 0

log_scroll_y   : f32 = 0

is_mouse_down := false
clicked       := false
is_hovering   := false

node_selected := -1
hash := 0

first_frame := true
muted := false
running := false
congestion_control_on := true
danger_danger_warning_idiots := false


tab_selected := MenuTabType.Graphs

pad_size       : f32 = 40
toolbar_height : f32 = 40
history_size   : int = 50
log_size       : int = 50
text_height    : f32 = 0
line_gap       : f32 = 0
graph_cols     :: 3
graph_size     :: 150
graph_gap      :: 40


TICK_INTERVAL_BASE :: 0.7
TICK_ANIM_DURATION_BASE :: 0.7
NEW_ANIM_DURATION_BASE :: 0.3
DONE_ANIM_DURATION_BASE :: 0.8
DROPPED_ANIM_DURATION :: 1.2

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
		bg_color      = Vec3{15,   15,  15}
		bg_color2     = Vec3{0,     0,   0}
		text_color    = Vec3{255, 255, 255}
		text_color2   = Vec3{180, 180, 180}
		text_color3   = Vec3{180, 180, 180}
		button_color  = Vec3{40,   40,  40}
		button_color  = Vec3{40,   40,  40}
		line_color    = Vec3{100, 100, 100}
		outline_color = Vec3{80,   80,  80}
		node_color    = Vec3{140, 140, 140}
		node_color2   = Vec3{220, 220, 220}
		graph_color   = Vec3{180, 180, 180}
		toolbar_color = Vec3{120, 120, 120}
	} else {
		bg_color      = Vec3{254, 252, 248}
		bg_color2     = Vec3{255, 255, 255}
		text_color    = Vec3{0,     0,   0}
		text_color2   = Vec3{80,   80,  80}
		text_color3   = Vec3{250, 250, 250}
		button_color  = Vec3{141, 119, 104}
		button_color2 = Vec3{191, 169, 154}
		line_color    = Vec3{219, 211, 205}
		outline_color = Vec3{219, 211, 205}
		node_color    = Vec3{129, 100,  80}
		node_color2   = Vec3{189, 160, 140}
		graph_color   = Vec3{69,   49,  34}
		toolbar_color = Vec3{219, 211, 205}
	}
}

reset_everything :: proc() {
	free_all(context.allocator)
	free_all(context.temp_allocator)

	init_state()
}

init_state :: proc() {
	set_timescale(1)

	nodes = make([dynamic]Node)
	conns = make([dynamic]Connection)
	exiting_packets = make([dynamic]Packet)
	inputs = make([dynamic]InputField)

	if ok := load_config(net_config, &nodes, &conns); !ok {
		fmt.printf("Failed to load config!\n")
		trap()
	}

	nodes_by_name = make(map[string]^Node)
	for n in &nodes {
		nodes_by_name[n.name] = &n
	}

	t = 0
	last_tick_t = t
	tick_count = 0
	frame_count = 0

	scale = 1
	min_width  = 10000
	min_height = 10000
	max_width  = 0
	max_height = 0

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

	append(&inputs, make_input_field(15))
	append(&inputs, make_input_field(15))
	append(&inputs, make_input_field(15))
	
	node_selected = -1
}

main :: proc() {
	global_data, _ := js.page_alloc(100)
	temp_data, _ := js.page_alloc(100)
    arena_init(&global_arena, global_data)
    arena_init(&temp_arena, temp_data)

    wasmContext.allocator = arena_allocator(&global_arena)
    wasmContext.temp_allocator = arena_allocator(&temp_arena)

    context = wasmContext

	init_state()
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
		for queue.len(node.avg_tick_history) >= history_size {
			queue.pop_front(&node.avg_tick_history)
		}
		queue.push_back(&node.avg_tick_history, average_packet_ticks)

		// Process TCP stuff
		tcp_tick(node)

		// Handle any packets we received
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
					if dst_node, conn, ok := get_connected_node(node_id, rule.interface_id); ok {
						if rand.float32() < conn.loss_factor {
							node.dropped += 1
							drop_packet(packet)
							node_log(node, "Dropped packet due to flaky connection:")
							node_log_packet(node, packet)
						} else {
							packet.ttl += 1
							append(&packet_sends, PacketSend{
								packet = packet,
								src = node,
								dst = dst_node,
							})
						}
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

		if queue.len(send.dst.buffer) >= send.dst.max_buffer_size {
			// fmt.printf("Buffer full, packet dropped\n")
			packet.dst_node.dropped += 1
			drop_packet(packet, true)
			continue
		}

		send.src.sent += 1
		send.dst.received += 1
		queue.push_back(&send.dst.buffer, packet)
	}

	// And extra fun stuff we do on each tick for testing:

	// Generate random packets, huzzah
	if danger_danger_warning_idiots {
		for i := 0; i < 2; i += 1 {
			generate_random_packet()
		}
	}

	send_data_via_tcp(nodes_by_name["me"], nodes_by_name["discord_1"], MUCH_ADO)
	send_data_via_tcp(nodes_by_name["discord_1"], nodes_by_name["discord_2"], CHEATER)
	send_data_via_tcp(nodes_by_name["discord_2"], nodes_by_name["discord_3"], GETTYSBURG)
	send_data_via_tcp(nodes_by_name["discord_3"], nodes_by_name["4chan"], NAVY_SEAL)

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

get_connected_node :: proc(my_node_id, my_interface_id: int) -> (^Node, ^Connection, bool) {
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

		return &nodes[other.node_id], conn, true
	}

	return nil, nil, false
}

send_data_via_tcp :: proc(src, dst: ^Node, data: string) -> bool {
	if sess, ok := tcp_open(src, dst.interfaces[0].ip); ok {
		// HACK: Open up destination for listening
		dst.listening = true
		
		//fmt.printf("Sending data from %s to %s: %s\n", src.name, dst.name, data)
		tcp_send(sess, data)
		return true
	}

	return false
}

random_seed: u64

@export
frame :: proc "contextless" (width, height: f32, dt: f32) -> bool {
    context = wasmContext
	defer free_all(context.temp_allocator)
	defer frame_count += 1

	// generate menu width
	tab_width : f32 = 600
	menu_offset := max(300, width - tab_width - pad_size)
	graph_width := menu_offset
	graph_height := height - toolbar_height

	// This is nasty code that allows me to do load-time things once the wasm context is init
	if first_frame {
		random_seed = u64(get_time())
		fmt.printf("Seed is 0x%X\n", random_seed)

		rand.set_global_seed(random_seed)
		get_session_storage("muted")

		pan = Vec2{(graph_width / 2) - (max_width / 2), (graph_height / 2) - (max_height / 2)}
		first_frame = false
	}

	defer if clicked {
		clicked = false
	}
	defer scroll_velocity = 0
	defer is_hovering = false

    t += dt

	// compute graph scale
	MIN_SCALE :: 0.1
	MAX_SCALE :: 2.5
	if pt_in_rect(mouse_pos, rect(0, toolbar_height, graph_width, height - toolbar_height)) {
		scale *= 1 + (0.05 * scroll_velocity * dt)
		if scale < MIN_SCALE {
			scale = MIN_SCALE
		} else if scale > MAX_SCALE {
			scale = MAX_SCALE
		}
	}

	// compute pan
	pan_delta := Vec2{}
	if is_mouse_down {
		if pt_in_rect(clicked_pos, rect(0, toolbar_height, graph_width, height - toolbar_height)) {
			pan_delta = mouse_pos - last_mouse_pos
		}
		last_mouse_pos = mouse_pos
	}
	pan += pan_delta

	// check intersections
	for node, idx in &nodes {
		if pt_in_rect(mouse_pos, Rect{(node.pos * scale) + pan, Vec2{node_size * scale, node_size * scale}}) {
			set_cursor("pointer")
			if clicked {
				node_selected = idx
			}
			break
		}
	}

	if running && t - last_tick_t >= tick_interval {
		tick()
	}

    canvas_clear()
    draw_rect(rect(graph_width, 0, width, height), 0, bg_color)
    draw_rect(rect(0, toolbar_height, menu_offset, height), 0, bg_color2)

	// Render graph view

	// render lines
	for conn in conns {
		node_a := nodes[conn.src_id.node_id]
		node_b := nodes[conn.dst_id.node_id]
		scaled_line(node_a.pos.x + (node_size / 2), node_a.pos.y + (node_size / 2), node_b.pos.x + (node_size / 2), node_b.pos.y + (node_size / 2), line_color.x, line_color.y, line_color.z, 255, 3)
	}

	// render nodes
	for node, idx in &nodes {
		color := node_color
		if idx == node_selected {
			color = node_color2
		}

    	scaled_rect(node.pos.x, node.pos.y, node_size, node_size, 5, color.x, color.y, color.z, 255)

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

					play_doot()
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
    draw_rect(rect(menu_offset, toolbar_height, tab_width + pad_size, height), 0, bg_color)

	// draw menu border
	draw_line(Vec2{menu_offset, toolbar_height}, Vec2{menu_offset, height}, 2, line_color)

	menu_offset += pad_size

	if node_selected != -1 {
		inspect_node := &nodes[node_selected]


		y: f32 = 0
		next_line := proc(y: ^f32) -> f32 {
			res := y^
			y^ += text_height + line_gap
			return res
		}

		y = toolbar_height + (pad_size / 2)
		draw_text(inspect_node.name, Vec2{menu_offset, next_line(&y)}, 1.25, default_font, text_color); y += 15
		
		text_height = get_text_height(1, default_font)
		menu_options := [3]MenuTab{{MenuTabType.Graphs, "Graphs"}, {MenuTabType.Logs, "Logs"}, {MenuTabType.Rules, "Rules"}}
		tab_offset : f32 = 0
		tab_pad : f32 = 10
		for opt in menu_options {
			text_width := measure_text(opt.label, 1, default_font)

			selected := tab_selected == opt.type
			if tab(rect(menu_offset + tab_offset, y, text_width + (tab_pad * 2), text_height + (tab_pad * 2)), opt.label, default_font, selected) {
				tab_selected = opt.type
			}

			tab_offset += text_width + (tab_pad * 2)
		}
		draw_line(Vec2{menu_offset - pad_size, y + text_height + (tab_pad * 2)}, Vec2{menu_offset + tab_width, y + text_height + (tab_pad * 2)}, 2, line_color)
		y += text_height + (tab_pad * 2)
		next_line(&y)

		#partial switch tab_selected {
		case .Graphs:
			draw_text(fmt.tprintf("Sent: %d, Received: %d, Dropped: %d", inspect_node.sent, inspect_node.received, inspect_node.dropped), Vec2{menu_offset, next_line(&y)}, 1, monospace_font, text_color2)

			buffer_used := min(inspect_node.max_buffer_size, queue.len(inspect_node.buffer))

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

			draw_text(fmt.tprintf("Avg Packet Ticks: %d, Avg Packet TTL: %d", average_packet_ticks, average_packet_ttl), Vec2{menu_offset, next_line(&y)}, 1, monospace_font, text_color2)

			// render history graphs
			graph_pos := Vec2{menu_offset, next_line(&y) + (pad_size / 2)}

			gi := 0
			next_graph_offset := proc(gi: ^int, y: ^f32) -> Vec2 {
				gx := f32(gi^ % graph_cols) * (graph_size + graph_gap)
				gy := f32(gi^ / graph_cols) * (graph_size + graph_gap)
				res := Vec2{gx, gy}
				
				if gi^ % graph_cols == 0 {
					y^ += graph_size + graph_gap
				}
				gi^ += 1
				
				return res
			}

			draw_graph("Packets Sent Over Time", &inspect_node.avg_sent_history, graph_pos + next_graph_offset(&gi, &y))
			draw_graph("Packets Received Over Time", &inspect_node.avg_recv_history, graph_pos + next_graph_offset(&gi, &y))
			draw_graph("Packets Dropped Over Time", &inspect_node.avg_drop_history, graph_pos + next_graph_offset(&gi, &y))
			draw_graph("Packet Ticks Over Time", &inspect_node.avg_tick_history, graph_pos + next_graph_offset(&gi, &y))
			for sess, i in &inspect_node.tcp_sessions {
				if congestion_control_on {
					draw_graph(fmt.tprintf("Session %d Congestion Window", i+1), &sess.cwnd_history, graph_pos + next_graph_offset(&gi, &y))
				}
				draw_graph(fmt.tprintf("Session %d Retransmit Queue", i+1), &sess.retransmit_history, graph_pos + next_graph_offset(&gi, &y))
			}
		case .Rules:
			rule_left: f32 = menu_offset

			draw_text("NICs:", Vec2{rule_left, next_line(&y)}, 1.125, default_font, text_color); y += 1
			for interface, i in inspect_node.interfaces {
				draw_text(fmt.tprintf("%d - %s", i + 1, ip_to_str(interface.ip)), Vec2{rule_left, next_line(&y)}, 1, monospace_font, text_color2)
			}

			next_line(&y)
			draw_text("Routing Rules:", Vec2{rule_left, next_line(&y)}, 1.125, default_font, text_color); y += 1

			ip_str_chunk := "255.255.255.255"
			ip_head_str := "IP:"
			subnet_head_str := "Subnet:"
			nic_head_str := "NIC:"

			ip_head_width     := measure_text(ip_head_str, 1, monospace_font)
			subnet_head_width := measure_text(subnet_head_str, 1, monospace_font)
			nic_head_width    := measure_text(nic_head_str, 1, monospace_font)
			field_width := measure_text(ip_str_chunk, 1, monospace_font) + 10
			text_height = get_text_height(1, monospace_font)
			box_height := (text_height * 2)

			for rule, idx in inspect_node.routing_rules {
				next_line(&y)
				ip_chunk := fmt.tprintf("%s %s", ip_head_str, ip_to_str(rule.ip))
				ip_width := measure_text(ip_chunk, 1, monospace_font)

				subnet_chunk := fmt.tprintf("%s %s", subnet_head_str, ip_to_str(rule.subnet_mask))
				subnet_width := measure_text(subnet_chunk, 1, monospace_font)

				nic_chunk := fmt.tprintf("%s %d", nic_head_str, rule.interface_id + 1)
				nic_width := measure_text(nic_chunk, 1, monospace_font)

				offset : f32 = 0
				draw_text(ip_chunk, Vec2{rule_left + offset, y}, 1, monospace_font, text_color2); offset += ip_head_width + field_width + 13
				draw_text(subnet_chunk, Vec2{rule_left + offset, y}, 1, monospace_font, text_color2); offset += subnet_head_width + field_width + 13
				draw_text(nic_chunk, Vec2{rule_left + offset, y}, 1, monospace_font, text_color2); offset += nic_head_width + field_width + 13

				// Delete rule
				if button(rect(rule_left + offset, y, box_height, box_height), "\uf1f8", icon_font) {
					ordered_remove(&inspect_node.routing_rules, idx)
				}
				y += 6
			}

			next_line(&y)
			y += 6

			field_offset : f32 = 0
			draw_text(ip_head_str, Vec2{rule_left + field_offset, y + (box_height / 2) - (text_height / 2)}, 1, monospace_font, text_color); field_offset += ip_head_width + 5
			draw_input(rect(rule_left + field_offset, y, field_width, box_height), 0); field_offset += field_width + 8

			draw_text(subnet_head_str, Vec2{rule_left + field_offset, y + (box_height / 2) - (text_height / 2)}, 1, monospace_font, text_color); field_offset += subnet_head_width + 5
			draw_input(rect(rule_left + field_offset, y, field_width, box_height), 1); field_offset += field_width + 8

			draw_text(nic_head_str, Vec2{rule_left + field_offset, y + (box_height / 2) - (text_height / 2)}, 1, monospace_font, text_color); field_offset += nic_head_width + 5
			draw_input(rect(rule_left + field_offset, y, field_width, box_height), 2); field_offset += field_width + 8

			// Add rule
			ip_str := strings.string_from_ptr(slice.as_ptr(inputs[0].buffer[:]), inputs[0].cursor)
			ip, ok := str_to_ip(ip_str)

			subnet_str := strings.string_from_ptr(slice.as_ptr(inputs[1].buffer[:]), inputs[1].cursor)
			subnet, ok2 := str_to_ip(subnet_str)

			interface := strings.string_from_ptr(slice.as_ptr(inputs[2].buffer[:]), inputs[2].cursor)
			val, ok3 := strconv.parse_int(interface)

			if ok && ok2 && ok3 {
				if button(rect(rule_left + field_offset, y, box_height, box_height), "+", monospace_font) {
					clear_input(0)
					clear_input(1)
					clear_input(2)
					append(&inspect_node.routing_rules, RoutingRule{ip = ip, subnet_mask = subnet, interface_id = val - 1})
				}
			}
		case .Logs:
			logs_left: f32 = menu_offset
			logs_height: f32 = 600
			logs_width: f32 = tab_width - pad_size

			draw_text("Connections:", Vec2{logs_left, next_line(&y)}, 1.125, default_font, text_color); y += 1

			mono_ch_width := measure_text("a", 1, monospace_font)
			line_width := int(math.floor((tab_width - pad_size) / mono_ch_width))

			if len(inspect_node.tcp_sessions) > 0 {
				for sess in inspect_node.tcp_sessions {
					draw_text(fmt.tprintf("%s: %v", ip_to_str(sess.ip), sess.state), Vec2{logs_left, next_line(&y)}, 1, monospace_font, text_color2)
					draw_text(fmt.tprintf("  SND: NXT=%v, WND=%v, UNA=%v", sess.snd_nxt, sess.snd_wnd, sess.snd_una), Vec2{logs_left, next_line(&y)}, 1, monospace_font, text_color2)
					draw_text(fmt.tprintf("  RCV: NXT=%v, WND=%v", sess.rcv_nxt, sess.rcv_wnd), Vec2{logs_left, next_line(&y)}, 1, monospace_font, text_color2)
					draw_text(fmt.tprintf("  ISS: %v, IRS: %v", sess.iss, sess.irs), Vec2{logs_left, next_line(&y)}, 1, monospace_font, text_color2)
					draw_text(fmt.tprintf("  CWND: %v, SENT=%v, ACKED=%v", sess.cwnd, sess.cwnd_sent, sess.cwnd_acked), Vec2{logs_left, next_line(&y)}, 1, monospace_font, text_color2)

					max_lines := 4
					leftover_lines := 4
					if strings.builder_len(sess.received_data) > 0 {
						data := strings.to_string(sess.received_data)

						draw_text("Received data:", Vec2{logs_left, next_line(&y)}, 1, monospace_font, text_color2)
						length_in_lines := int(math.ceil(f32(len(data))/f32(line_width)))
						visible_data := data[max(0, (length_in_lines-max_lines)*line_width):]
						for i := 0; i < len(visible_data); i += line_width {
							draw_text(visible_data[i:min(i+line_width, len(visible_data))], Vec2{logs_left, next_line(&y)}, 1, monospace_font, text_color2)
						}

						leftover_lines -= length_in_lines
					} else {
						next_line(&y)
					}

					for i := 0; i < leftover_lines; i += 1 {
						next_line(&y)	
					}
				}

				next_line(&y)

				log_lines := 25
				outline_width : f32 = 2
				draw_text("Logs:", Vec2{logs_left, next_line(&y)}, 1.125, default_font, text_color); y += 1
				draw_rect(rect(logs_left, y + 4, logs_width, logs_height), 2, bg_color2)

				draw_rect_outline(rect(logs_left - outline_width - (outline_width / 2), y - outline_width - (outline_width / 2) + 4, logs_width + outline_width + (outline_width / 2), logs_height + outline_width + (outline_width / 2)), outline_width, outline_color)

				logs_left += 5

				if queue.len(inspect_node.logs) > log_lines {
					draw_text("...", Vec2{logs_left, next_line(&y)}, 1, monospace_font, text_color2)
				} else {
					next_line(&y)
				}

				iter_start := queue.len(inspect_node.logs) - min(log_lines, queue.len(inspect_node.logs))
				iter_end := queue.len(inspect_node.logs) - 1

				current_tick := -1
				tick_changed := false
				time_str := ""
				time_width : f32 = 0
				time_gap : f32 = 10
				for i := iter_start; i <= iter_end; i += 1 {
					msg := queue.get(&inspect_node.logs, i)

					if msg.timestamp != current_tick {
						current_tick = msg.timestamp
						tick_changed = true

						time_str = fmt.tprintf("%d", msg.timestamp)
						time_width = measure_text(time_str, 1, monospace_font)
					}

					if tick_changed {
						y += text_height
						draw_text(time_str, Vec2{logs_left, y}, 1, monospace_font, text_color)
					}
					draw_text(msg.content, Vec2{logs_left + time_width + time_gap, next_line(&y)}, 1, monospace_font, text_color2)

					tick_changed = false
				}
			} else {
				draw_text("Nothing yet!", Vec2{logs_left, next_line(&y)}, 1, monospace_font, text_color2); y += 1
			}
		}
	}

	// draw legend
	top_pad := toolbar_height + 20
	draw_circle(Vec2{20 + packet_size, top_pad+packet_size+20*0}, packet_size, COLOR_SYN)
	draw_circle(Vec2{20 + packet_size, top_pad+packet_size+20*1}, packet_size, COLOR_ACK)
	draw_circle(Vec2{20 + packet_size, top_pad+packet_size+20*2}, packet_size, COLOR_SYNACK)
	draw_circle(Vec2{20 + packet_size, top_pad+packet_size+20*3}, packet_size, COLOR_RST)
	draw_circle(Vec2{20 + packet_size, top_pad+packet_size+20*4}, packet_size, text_color)
	draw_text("SYN",    Vec2{38, top_pad+20*0}, 1, default_font, text_color)
	draw_text("ACK",    Vec2{38, top_pad+20*1}, 1, default_font, text_color)
	draw_text("SYNACK", Vec2{38, top_pad+20*2}, 1, default_font, text_color)
	draw_text("RST",    Vec2{38, top_pad+20*3}, 1, default_font, text_color)
	draw_text("DATA",   Vec2{38, top_pad+20*4}, 1, default_font, text_color)

	cc_btn_text := congestion_control_on ? "Congestion Control ON" : "Congestion Control OFF"
	if button(rect(20, top_pad+20*5, 180, 30), cc_btn_text, default_font) {
		congestion_control_on = !congestion_control_on
	}

	draw_text(fmt.tprintf("ACK delay: %d", ack_delay), Vec2{20, 200}, 1, default_font, text_color)
	if button(rect(100, 195, 20, 20), "-", monospace_font) {
		ack_delay = max(0, ack_delay - 1)
	}
	if button(rect(125, 195, 20, 20), "+", monospace_font) {
		ack_delay = ack_delay + 1
	}

	// draw toolbar
	edge_pad : f32 = 10
	button_height : f32 = 30
	button_width  : f32 = 30
	button_pad    : f32 = 8
	if button(rect(edge_pad, (toolbar_height / 2) - (button_height / 2), button_width, button_height), running ? "\uf04c" : "\uf04b", icon_font) {
		running = !running
	}
	if button(rect(edge_pad + button_width + button_pad, (toolbar_height / 2) - (button_height / 2), button_width, button_height), "\uf0e2", icon_font) {
		reset_everything()
		running = false
		return true
	}
	if !running {
		if button(rect(edge_pad + ((button_width + button_pad) * 2), (toolbar_height / 2) - (button_height / 2), button_width, button_height), "\uf051", icon_font) {
			tick()
		}
	}
	if button(rect(edge_pad + ((button_width + button_pad) * 3), (toolbar_height / 2) - (button_height / 2), button_width, button_height), "\uf04e", icon_font) {
		if timescale == 1 {
			set_timescale(0.4)
		} else if timescale == 0.4 {
			set_timescale(0.2)
		} else {
			set_timescale(1)
		}
	}
	if button(rect(edge_pad + ((button_width + button_pad) * 4), (toolbar_height / 2) - (button_height / 2), button_width, button_height), "\uf071", icon_font) {
		danger_danger_warning_idiots = !danger_danger_warning_idiots
	}
	if button(rect(width - edge_pad - button_width, (toolbar_height / 2) - (button_height / 2), button_width, button_height), muted ? "\uf028" : "\uf026", icon_font) {
		muted = !muted
		set_session_storage("muted", muted ? "true": "false")
	}

	if !is_hovering {
		reset_cursor()
	}

	seed_str := fmt.tprintf("Seed: 0x%X", random_seed)
	seed_width := measure_text(seed_str, 1, monospace_font)
	draw_text(seed_str, Vec2{width - seed_width - 10, height - text_height - 24}, 1, monospace_font, text_color2)

	hash_str := fmt.tprintf("Build: 0x%X", abs(hash))
	hash_width := measure_text(hash_str, 1, monospace_font)
	draw_text(hash_str, Vec2{width - hash_width - 10, height - text_height - 10}, 1, monospace_font, text_color2)

	remove_packets(&exiting_packets, dead_packets[:])
    return true
}

generate_random_packet :: proc() {
	src_id := int(rand.int31()) % len(nodes)
	dst_id := int(rand.int31()) % len(nodes)

	if src_id == dst_id {
		return
	}

	if queue.len(nodes[src_id].buffer) >= nodes[src_id].max_buffer_size {
		return
	}

	send_packet(&nodes[src_id], Packet{
		src_ip = nodes[src_id].interfaces[0].ip,
		dst_ip = nodes[dst_id].interfaces[0].ip,
		color_for_real = Vec3{f32(rand_int(80, 230)), f32(rand_int(80, 230)), f32(rand_int(80, 230))},
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

	color := packet.color != nil ? packet.color^ : packet.color_for_real
	scaled_circle(pos.x, pos.y, size, color.x, color.y, color.z, 255)
	packet.last_pos = packet.pos
	packet.pos = pos
}

draw_input :: proc(r: Rect, infield_idx: int) {
	infield := &inputs[infield_idx]

	outline_width : f32 = 1
	draw_rect_outline(rect(r.pos.x - outline_width, r.pos.y - outline_width, r.size.x + outline_width, r.size.y + outline_width), outline_width, outline_color)

	if pt_in_rect(mouse_pos, r) {
		set_cursor("text")
	}
	if clicked {
		if pt_in_rect(mouse_pos, r) {
			infield.has_focus = true
		} else {
			infield.has_focus = false
		}
	}

	draw_rect(r, 1, bg_color2)

	text := strings.string_from_ptr(slice.as_ptr(infield.buffer[:]), infield.cursor)
	text_width := measure_text(text, 1, monospace_font)
	text_height = get_text_height(1, monospace_font)
	draw_text(text, Vec2{r.pos.x + 4, r.pos.y + ((text_height + 5) / 2)}, 1, monospace_font, text_color2)

	if infield.has_focus {
		infield.alpha -= 1.35
		if infield.alpha < 1 {
			infield.alpha = 255
		}
		draw_line(Vec2{r.pos.x + 4 + text_width + 2, r.pos.y}, Vec2{r.pos.x + 4 + text_width + 2, r.pos.y + r.size.y}, 1, text_color, infield.alpha)
	}
}
clear_input :: proc(infield_idx: int) {
	infield := &inputs[infield_idx]
	infield.has_focus = false
	mem.zero_slice(infield.buffer[:])
	infield.cursor = 0
}

draw_graph :: proc(header: string, history: ^queue.Queue(u32), pos: Vec2) {
	line_width : f32 = 1
	graph_edge_pad : f32 = 15

	max_val : u32 = 0
	min_val : u32 = 100
	for i := 0; i < queue.len(history^); i += 1 {
		entry := queue.get(history, i)
		max_val = max(max_val, entry)
		min_val = min(min_val, entry)
	}
	max_range := max_val - min_val

	text_width := measure_text(header, 1, default_font)
	center_offset := (graph_size / 2) - (text_width / 2)
	draw_text(header, Vec2{pos.x + center_offset, pos.y}, 1, default_font, text_color)

	graph_top := pos.y + text_height + line_gap
	draw_rect(rect(pos.x, graph_top, graph_size, graph_size), 0, bg_color2)
	draw_rect_outline(rect(pos.x, graph_top, graph_size, graph_size), 2, outline_color)

	draw_line(Vec2{pos.x - 5, graph_top + graph_size - graph_edge_pad}, Vec2{pos.x + 5, graph_top + graph_size - graph_edge_pad}, 1, graph_color)
	draw_line(Vec2{pos.x - 5, graph_top + graph_edge_pad}, Vec2{pos.x + 5, graph_top + graph_edge_pad}, 1, graph_color)

	if queue.len(history^) > 1 {
		high_str := fmt.tprintf("%d", max_val)
		high_width := measure_text(high_str, 1, default_font) + line_gap
		draw_text(high_str, Vec2{(pos.x - 5) - high_width, graph_top + graph_edge_pad - (text_height / 2) + 1}, 1, default_font, text_color)

		low_str := fmt.tprintf("%d", min_val)
		low_width := measure_text(low_str, 1, default_font) + line_gap
		draw_text(low_str, Vec2{(pos.x - 5) - low_width, graph_top + graph_size - graph_edge_pad - (text_height / 2) + 2}, 1, default_font, text_color)
	}

	graph_y_bounds := graph_size - (graph_edge_pad * 2)
	graph_x_bounds := graph_size - graph_edge_pad

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

		point_x := pos.x + point_x_offset + (graph_edge_pad / 2)
		point_y := graph_top + graph_size - point_y_offset - graph_edge_pad

		if queue.len(history^) > 1  && i > 0 {
			draw_line(Vec2{last_x, last_y}, Vec2{point_x, point_y}, line_width, graph_color)
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

button :: proc(in_rect: Rect, text: string, font: string) -> bool {
	draw_rect(in_rect, 3, button_color)
	text_width := measure_text(text, 1, font)
	text_height = get_text_height(1, font)
	draw_text(text, Vec2{in_rect.pos.x + in_rect.size.x/2 - text_width/2, in_rect.pos.y + (in_rect.size.y / 2) - (text_height / 2)}, 1, font, text_color3)

	if pt_in_rect(mouse_pos, in_rect) {
		set_cursor("pointer")
		if clicked {
			return true
		}
	}
	return false
}

tab :: proc(in_rect: Rect, text: string, font: string, selected: bool) -> bool {
	text_width := measure_text(text, 1, font)
	text_height = get_text_height(1, font)

	if selected {
		draw_rect(in_rect, 0, button_color)
		draw_rect_outline(in_rect, 1, button_color)
		draw_text(text, Vec2{in_rect.pos.x + in_rect.size.x/2 - text_width/2, in_rect.pos.y + (in_rect.size.y / 2) - (text_height / 2)}, 1, font, text_color3)
	} else {
		draw_rect(in_rect, 0, button_color2)
		draw_rect_outline(in_rect, 1, button_color)
		draw_text(text, Vec2{in_rect.pos.x + in_rect.size.x/2 - text_width/2, in_rect.pos.y + (in_rect.size.y / 2) - (text_height / 2)}, 1, font, text_color)
	}


	if pt_in_rect(mouse_pos, in_rect) && !selected {
		set_cursor("pointer")
		if clicked {
			return true
		}
	}

	return false
}
