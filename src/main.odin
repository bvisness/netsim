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

Vec2 :: [2]f32
Rect :: struct {
	pos: Vec2,
	size: Vec2,
}

Node :: struct {
	pos: Vec2,

	name: string,
	interfaces: []Interface,
	routing_rules: []RoutingRule,

	buffer: queue.Queue(Packet),
}

Interface :: struct {
	ip: u32,

	// stats?
	// buffers?
}

RoutingRule :: struct {
	ip: u32, 
	subnet_mask: u32,
	interface_id: int,
}

Connection :: struct {
	src_id: ConnectionID,
	dst_id: ConnectionID,

	loss_factor: f32, // 0 = no loss, 1 = all packets are dropped
}

ConnectionID :: struct {
	node_id: int,
	interface_id: int,
}

Packet :: struct {
	pos: Vec2,

	src_ip: u32,
	dst_ip: u32,

	// Properties for animation
	anim: PacketAnimation,
	// NOTE(ben): If / when we add node deletion, this could get into use-after-free territory.
	// Maybe avoid it by not allowing editing while simulating...
	src_node: ^Node,
	dst_node: ^Node,
	src_bufid: int,
	dst_bufid: int,

	created_t: f32, // when this transitioned to New
}

PacketAnimation :: enum {
	None,
	New,
	Delivered,
	Dropped,
}

nodes : [dynamic]Node
conns : [dynamic]Connection
exiting_packets : [dynamic]Packet

t: f32 = 0
min_width   : f32 = 10000
min_height  : f32 = 10000
max_width   : f32 = 0
max_height  : f32 = 0
pad_size    : f32 = 40
buffer_size : int = 10
TICK_INTERVAL_S :: 1
TICK_ANIM_DURATION_S :: 0.6
NEW_ANIM_DURATION_S :: 0.4
DONE_ANIM_DURATION_S :: 0.6
DROPPED_ANIM_DURATION_S :: 0.8

main :: proc() {
    arena_init(&global_arena, global_arena_data[:])
    arena_init(&temp_arena, temp_arena_data[:])

    wasmContext.allocator = arena_allocator(&global_arena)
    wasmContext.temp_allocator = arena_allocator(&temp_arena)

    context = wasmContext

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
	clear(&exiting_packets)

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
			append(&exiting_packets, packet)
			continue
		}

		// Uh, route it somewhere else
		for rule in node.routing_rules {
			masked_dest := packet.dst_ip & rule.subnet_mask
			if masked_dest == rule.ip {
				if dst_node, ok := get_connected_node(node_id, rule.interface_id); ok {
					append(&packet_sends, PacketSend{
						packet = packet,
						src = &node,
						dst = dst_node,
					})
					// fmt.printf("Node %d: here have packet!!\n", node_id)
				} else {
					// fmt.printf("Node %d: bad routing rule! discarding packet.\n", node_id)
					packet.anim = PacketAnimation.Dropped
					append(&exiting_packets, packet)
				}
				continue nextnode
			}
		}

		// the hell is this packet
		// fmt.printf("Node %d: the hell is this packet? discarding\n", node_id)
		packet.anim = PacketAnimation.Dropped
		append(&exiting_packets, packet)
	}

	for send in packet_sends {
		if queue.len(send.dst.buffer) >= buffer_size {
			// fmt.printf("Buffer full, packet dropped\n")
			packet := send.packet
			packet.anim = PacketAnimation.Dropped
			append(&exiting_packets, packet)
			continue
		}

		packet := send.packet
		packet.anim = PacketAnimation.None
		packet.src_node = send.src
		packet.src_bufid = 0 // top of the buffer
		packet.dst_node = send.dst
		packet.dst_bufid = queue.len(send.dst.buffer)

		queue.push_back(&send.dst.buffer, packet)
	}
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
	defer free_all(context.temp_allocator)

    t += dt

	if t - last_tick_t >= TICK_INTERVAL_S {
		defer last_tick_t = t
		defer tick_count += 1
		
		tick()

		if tick_count % 3 == 0 {
			for i := 0; i < 10; i += 1 {
				src_id := int(rand.int31()) % len(nodes)
				dst_id := int(rand.int31()) % len(nodes)

				if queue.len(nodes[src_id].buffer) >= buffer_size {
					continue
				}

				queue.push_back(&nodes[src_id].buffer, Packet{
					anim = PacketAnimation.New,
					src_ip = nodes[src_id].interfaces[0].ip,
					dst_ip = nodes[dst_id].interfaces[0].ip,

					// visualization
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

	// render padded background
	canvas_rect(pad_size, pad_size, max_width, max_height, 0, 220, 220, 220, 255)

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
		if queue.len(node.buffer) > 0 {
			pos := Vec2{node.pos.x + ((node_size / 2) - (packet_size / 2)), node.pos.y + ((node_size / 2) - (packet_size / 2))}
			color : f32 = ((-math.cos_f32(t) + 1) / 2) * 255

			canvas_rect(pos.x, pos.y, packet_size, packet_size, packet_size / 2, int(color), 100, 100, 255)
		}

		// Draw node packets
		for i := 0; i < queue.len(node.buffer); i += 1 {
			packet := queue.get_ptr(&node.buffer, i)

			src_pos := pos_in_buffer(packet.src_node, packet.src_bufid)
			dst_pos := pos_in_buffer(packet.dst_node, packet.dst_bufid)
			pos_t := clamp(0, 1, (t - last_tick_t) / TICK_ANIM_DURATION_S)
			pos := math.lerp(src_pos, dst_pos, ease_in_out(pos_t))

			size := packet_size_in_buffer
			if packet.anim == PacketAnimation.New {
				size_t := clamp(0, 1, (t - packet.created_t) / NEW_ANIM_DURATION_S)
				size = math.lerp(f32(0), packet_size_in_buffer, ease_in_out(size_t))
			}

			canvas_circle(pos.x, pos.y, size, 100, 100, 100, 255)
			packet.pos = pos
		}
	}

	// Draw exiting packets
	for packet in exiting_packets {
		#partial switch packet.anim {
		case .Delivered:
			anim_t := clamp(0, 1, (t - last_tick_t) / DONE_ANIM_DURATION_S)
			pos := math.lerp(packet.pos, packet.dst_node.pos + Vec2{node_size/2, node_size/2}, ease_in_back(anim_t))
			size := math.lerp(packet_size_in_buffer, 0, ease_in(anim_t))
			canvas_circle(pos.x, pos.y, size, 100, 100, 100, 255)
		case .Dropped:
			anim_t := clamp(0, 1, (t - last_tick_t) / DROPPED_ANIM_DURATION_S)
			pos := math.lerp(packet.pos, packet.pos + Vec2{0, 25}, ease_in(anim_t))
			alpha := int(math.lerp(f32(255), f32(0), anim_t))
			canvas_circle(pos.x, pos.y, packet_size_in_buffer, 100, 100, 100, alpha)
		}
	}

    return true
}
