package main

import "core:container/queue"
import "core:fmt"
import "core:intrinsics"
import "core:math"
import "core:math/rand"
import "core:mem"
import "core:runtime"
import "core:strings"

global_arena_data := [1_000_000]byte{}
global_arena := Arena{}

temp_arena_data := [1_000_000]byte{}
temp_arena := Arena{}

wasmContext := runtime.default_context()

nodes : [dynamic]Node
conns : [dynamic]Connection
exiting_packets : [dynamic]Packet

t: f32 = 0
min_width   : f32 = 10000
min_height  : f32 = 10000
max_width   : f32 = 0
max_height  : f32 = 0
pad_size    : f32 = 40
buffer_size : int = 15
running := true

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

main :: proc() {
    arena_init(&global_arena, global_arena_data[:])
    arena_init(&temp_arena, temp_arena_data[:])

    wasmContext.allocator = arena_allocator(&global_arena)
    wasmContext.temp_allocator = arena_allocator(&temp_arena)

    context = wasmContext

	set_timescale(1)

	nodes = make([dynamic]Node)
	conns = make([dynamic]Connection)
	exiting_packets = make([dynamic]Packet)

	if ok := load_config(net_config, &nodes, &conns); !ok {
		fmt.printf("Failed to load config!\n")
		trap()
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

		node.pos.x = (node.pos.x - min_width) + (pad_size * 2)
		node.pos.y = (node.pos.y - min_height) + (pad_size * 2)

		if node.pos.x > max_width {
			max_width = node.pos.x
		}

		if node.pos.y > max_height {
			max_height = node.pos.y
		}
	}
	max_width += node_size
	max_height += node_size
}

tick :: proc() {	
	PacketSend :: struct {
		packet: Packet,
		src: ^Node,
		dst: ^Node,
	}
	packet_sends := make([dynamic]PacketSend, context.temp_allocator)

	nextnode:
	for node, node_id in &nodes {
		// Update packet animation data (for everything but the top one, which will be popped)
		for i := 1; i < queue.len(node.buffer); i += 1 {
			packet := queue.get_ptr(&node.buffer, i)
			packet.anim = PacketAnimation.None
			packet.src_node = &node
			packet.src_bufid = i
			packet.dst_node = &node
			packet.dst_bufid = i - 1
		}
 
		// Try to send
		packet, ok := queue.pop_front_safe(&node.buffer)
		if !ok {
			continue
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
			packet.anim = PacketAnimation.Delivered
			packet.dst_node = &node
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
					append(&packet_sends, PacketSend{
						packet = packet,
						src = &node,
						dst = dst_node,
					})
					// fmt.printf("Node %d: here have packet!!\n", node_id)
				} else {
					// fmt.printf("Node %s [%s]: bad routing rule! discarding packet.\n", node.name, ip_to_str(node.interfaces[0].ip))
					// fmt.printf("%s -> %s\n", ip_to_str(packet.src_ip), ip_to_str(packet.dst_ip))
					drop_packet(packet)
					running = false
				}
				continue nextnode
			}
		}

		// the hell is this packet
		// fmt.printf("Node %s [%s]: the hell is this packet? discarding\n", node.name, ip_to_str(node.interfaces[0].ip))
		// fmt.printf("%s -> %s\n", ip_to_str(packet.src_ip), ip_to_str(packet.dst_ip))
		drop_packet(packet)
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
			drop_packet(packet, true)
			continue
		}

		queue.push_back(&send.dst.buffer, packet)
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

@export
frame :: proc "contextless" (width, height: f32, dt: f32) -> bool {
    context = wasmContext
	if !running {
		return false
	}

	defer free_all(context.temp_allocator)

    t += dt

	if t - last_tick_t >= tick_interval {
		defer last_tick_t = t
		defer tick_count += 1
		
		tick()

		if tick_count % 3 == 0 {
			for i := 0; i < 10; i += 1 {
				src_id := int(rand.int31()) % len(nodes)
				dst_id := int(rand.int31()) % len(nodes)

				if src_id == dst_id {
					continue
				}

				if queue.len(nodes[src_id].buffer) >= buffer_size {
					continue
				}

				queue.push_back(&nodes[src_id].buffer, Packet{
					anim = PacketAnimation.New,
					src_ip = nodes[src_id].interfaces[0].ip,
					dst_ip = nodes[dst_id].interfaces[0].ip,

					// visualization
					color = Vec3{f32(rand_int(100, 200)), f32(rand_int(100, 200)), f32(rand_int(100, 200))},
					src_node = &nodes[src_id],
					dst_node = &nodes[src_id], // not a mistake!
					src_bufid = queue.len(nodes[src_id].buffer),
					dst_bufid = queue.len(nodes[src_id].buffer),
					created_t = t,
				})
			}
		}
	}

    canvas_clear()

	// render lines
	for conn in conns {
		node_a := nodes[conn.src_id.node_id]
		node_b := nodes[conn.dst_id.node_id]
		canvas_line(node_a.pos.x + (node_size / 2), node_a.pos.y + (node_size / 2), node_b.pos.x + (node_size / 2), node_b.pos.y + (node_size / 2), 180, 180, 180, 255, 3)
	}

	// render nodes
	for node in &nodes {
    	canvas_rect(node.pos.x, node.pos.y, node_size, node_size, 5, 0, 0, 0, 255)

		// Draw interface IPs
		// ip_pad : f32 = 5 
		// ip_offset : f32 = 16
		// for interface, i in node.interfaces {
		// 	ip_store := [16]u8{}
		// 	ip_str := ip_to_str(interface.ip, ip_store[:])
		// 	canvas_text(ip_str, node.pos.x, node.pos.y + node_size + ip_pad + (ip_offset * f32(i)), 0, 0, 0, 255)
		// }

		// Draw label
		canvas_text(node.name, node.pos.x, node.pos.y - 16, 0, 0, 0, 255)

		// Draw ???
		// if queue.len(node.buffer) > 0 {
		// 	pos := Vec2{node.pos.x + ((node_size / 2) - (packet_size / 2)), node.pos.y + ((node_size / 2) - (packet_size / 2))}
		// 	color : f32 = ((-math.cos_f32(t) + 1) / 2) * 255

		// 	canvas_rect(pos.x, pos.y, packet_size, packet_size, packet_size / 2, int(color), 100, 100, 255)
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
			canvas_circle(pos.x, pos.y, size, packet.color.x, packet.color.y, packet.color.z, alpha)

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
				}

				packet.velocity += Vec2{0, 180} * dt
				packet.pos += packet.velocity * dt
				anim_t := (t - packet.dropped_t) / DROPPED_ANIM_DURATION
				alpha := math.lerp(f32(255), f32(0), anim_t)
				canvas_circle(packet.pos.x, packet.pos.y, packet_size_in_buffer, packet.color.x, packet.color.y, packet.color.z, alpha)

				if anim_t > 1 {
					append(&dead_packets, i)
				}
			}
		}
	}

	remove_packets(&exiting_packets, dead_packets[:])

    return true
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

	canvas_circle(pos.x, pos.y, size, packet.color.x, packet.color.y, packet.color.z, 255)
	packet.last_pos = packet.pos
	packet.pos = pos
}

remove_packets :: proc(packets: ^[dynamic]Packet, indexes: []int) {
	for i := len(indexes)-1; i >= 0; i -= 1 {
		ordered_remove(packets, indexes[i])
	}
}
