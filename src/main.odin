package main

import "core:container/queue"
import "core:fmt"
import "core:intrinsics"
import "core:math"
import "core:mem"
import "core:runtime"
import "core:strings"

global_arena_data := [1_000_000]byte{}
global_arena := Arena{}

temp_arena_data := [1_000_000]byte{}
temp_arena := Arena{}

wasmContext := runtime.default_context()

Vec2 :: distinct [2]f32

Node :: struct {
	pos: Vec2,

	interfaces: [4]Interface,
	routing_rules: [10]RoutingRule,

	buffer: queue.Queue(Packet),
}

Interface :: struct {
	ip: u32,

	// stats?
	// buffers?
}

RoutingRule :: struct {
	ip: u32, subnet_mask: u32,
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
}

nodes : [dynamic]Node
conns : [dynamic]Connection

t: f32 = 0
max_width   : f32 = 0
max_height  : f32 = 0
pad_size    : f32 = 30
node_size   : f32 = 50
packet_size : f32 = 30

make_node :: proc(pos: Vec2, ips: []string, routing_rules: []RoutingRule) -> Node {
	n := Node{pos = pos}
	for ip, i in ips { 
		n.interfaces[i] = Interface{
			ip = must_str_to_ip(ip),
		}
	}
	for rule, i in routing_rules {
		n.routing_rules[i] = rule
	}
	if ok := queue.init(&n.buffer, 10); !ok {
		fmt.println("Successfully failed to init queue.")
		intrinsics.trap()
	}
	return n
}

main :: proc() {
    fmt.println("Hellope!")

    arena_init(&global_arena, global_arena_data[:])
    arena_init(&temp_arena, temp_arena_data[:])

    wasmContext.allocator = arena_allocator(&global_arena)
    wasmContext.temp_allocator = arena_allocator(&temp_arena)

    context = wasmContext

	nodes = make([dynamic]Node, 0)
	conns = make([dynamic]Connection, 0)

	me := make_node(Vec2{0, 400}, []string{"2.2.2.123"}, []RoutingRule{
		{
			ip = must_str_to_ip("0.0.0.0"), subnet_mask = must_str_to_ip("0.0.0.0"),
			interface_id = 0,
		},
	})
	comcast := make_node(Vec2{200, 400}, []string{"2.2.2.1", "2.2.2.2", "2.2.2.3"}, []RoutingRule{
		{ // Me
			ip = must_str_to_ip("2.2.2.123"), subnet_mask = must_str_to_ip("255.255.255.255"),
			interface_id = 0,
		},
		{ // Google
			ip = must_str_to_ip("3.0.0.0"), subnet_mask = must_str_to_ip("255.0.0.0"),
			interface_id = 1,
		},
		{ // Cloudflare
			ip = must_str_to_ip("4.0.0.0"), subnet_mask = must_str_to_ip("255.0.0.0"),
			interface_id = 2,
		},
		{ // Discord
			ip = must_str_to_ip("5.0.0.0"), subnet_mask = must_str_to_ip("255.0.0.0"),
			interface_id = 2,
		},
	})
	google := make_node(Vec2{400, 200}, []string{"3.3.3.1", "3.3.3.2"}, []RoutingRule{
		{ // Comcast
			ip = must_str_to_ip("2.0.0.0"), subnet_mask = must_str_to_ip("255.0.0.0"),
			interface_id = 0,
		},
		{ // Cloudflare
			ip = must_str_to_ip("4.0.0.0"), subnet_mask = must_str_to_ip("255.0.0.0"),
			interface_id = 1,
		},
		{ // Discord
			ip = must_str_to_ip("5.0.0.0"), subnet_mask = must_str_to_ip("255.0.0.0"),
			interface_id = 1,
		},
	})
	cloudflare := make_node(Vec2{400, 600}, []string{"4.4.4.1", "4.4.4.2", "4.4.4.3"}, []RoutingRule{
		{ // Comcast
			ip = must_str_to_ip("2.0.0.0"), subnet_mask = must_str_to_ip("255.0.0.0"),
			interface_id = 0,
		},
		{ // Google
			ip = must_str_to_ip("3.0.0.0"), subnet_mask = must_str_to_ip("255.0.0.0"),
			interface_id = 1,
		},
		{ // Discord
			ip = must_str_to_ip("5.0.0.0"), subnet_mask = must_str_to_ip("255.0.0.0"),
			interface_id = 2,
		},
	})
	discord_hub := make_node(Vec2{600, 600}, []string{"5.5.5.1", "5.5.5.2", "5.5.5.2", "5.5.5.2"}, []RoutingRule{
		{ // Cloudflare
			ip = must_str_to_ip("4.0.0.0"), subnet_mask = must_str_to_ip("255.0.0.0"),
			interface_id = 0,
		},
		{ // Discord 1
			ip = must_str_to_ip("5.5.100.1"), subnet_mask = must_str_to_ip("255.255.255.255"),
			interface_id = 1,
		},
		{ // Discord 2
			ip = must_str_to_ip("5.5.100.2"), subnet_mask = must_str_to_ip("255.255.255.255"),
			interface_id = 2,
		},
		{ // Discord 3
			ip = must_str_to_ip("5.5.100.3"), subnet_mask = must_str_to_ip("255.255.255.255"),
			interface_id = 3,
		},
	})
	discord_1 := make_node(Vec2{700, 500}, []string{"5.5.100.1"}, []RoutingRule{
		{
			ip = must_str_to_ip("0.0.0.0"), subnet_mask = must_str_to_ip("0.0.0.0"),
			interface_id = 0,
		}
	})
	discord_2 := make_node(Vec2{700, 600}, []string{"5.5.100.2"}, []RoutingRule{
		{
			ip = must_str_to_ip("0.0.0.0"), subnet_mask = must_str_to_ip("0.0.0.0"),
			interface_id = 0,
		}
	})
	discord_3 := make_node(Vec2{700, 700}, []string{"5.5.100.3"}, []RoutingRule{
		{
			ip = must_str_to_ip("0.0.0.0"), subnet_mask = must_str_to_ip("0.0.0.0"),
			interface_id = 0,
		}
	})

	queue.push_back(&me.buffer, Packet{
		src_ip = me.interfaces[0].ip,
		dst_ip = discord_3.interfaces[0].ip,
	})

	append(&nodes,
		me,
		comcast,
		google,
		cloudflare,
		discord_hub, discord_1, discord_2, discord_3,
	)

	for i := 0; i < len(nodes); i += 1 {
		node := &nodes[i]
		node.pos.x += (pad_size * 2)
		node.pos.y += (pad_size * 2)

		if node.pos.x > max_width {
			max_width = node.pos.x
		}

		if node.pos.y > max_height {
			max_height = node.pos.y
		}
	}
	max_width += node_size
	max_height += node_size

	append(&conns,
		Connection{ // me <-> comcast
			src_id = ConnectionID{node_id = 0},
			dst_id = ConnectionID{node_id = 1},
		},
		Connection{ // comcast <-> google
			src_id = ConnectionID{node_id = 1, interface_id = 1},
			dst_id = ConnectionID{node_id = 2},
		},
		Connection{ // comcast <-> cloudflare
			src_id = ConnectionID{node_id = 1, interface_id = 2},
			dst_id = ConnectionID{node_id = 3},
		},
		Connection{ // google <-> cloudflare
			src_id = ConnectionID{node_id = 2, interface_id = 1},
			dst_id = ConnectionID{node_id = 3, interface_id = 1},
		},
		Connection{ // cloudflare <-> discord hub
			src_id = ConnectionID{node_id = 3, interface_id = 2},
			dst_id = ConnectionID{node_id = 4},
		},
		Connection{ // discord hub <-> discord 1
			src_id = ConnectionID{node_id = 4, interface_id = 1},
			dst_id = ConnectionID{node_id = 5},
		},
		Connection{ // discord hub <-> discord 2
			src_id = ConnectionID{node_id = 4, interface_id = 2},
			dst_id = ConnectionID{node_id = 6},
		},
		Connection{ // discord hub <-> discord 3
			src_id = ConnectionID{node_id = 4, interface_id = 3},
			dst_id = ConnectionID{node_id = 7},
		},
	)
}

trap :: proc() {
	intrinsics.trap()
}

tick :: proc() {
	PacketSend :: struct {
		packet: Packet,
		node: ^Node,
	}
	packet_sends := make([dynamic]PacketSend, context.temp_allocator)

	nextnode:
	for _, node_id in nodes {
		node := &nodes[node_id]

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
			fmt.printf("Node %d: thank you for the packet in these trying times\n", node_id)
			continue
		}

		// Uh, route it somewhere else
		for rule in node.routing_rules {
			masked_dest := packet.dst_ip & rule.subnet_mask
			if masked_dest == rule.ip {
				if dst_node, ok := get_connected_node(node_id, rule.interface_id); ok {
					append(&packet_sends, PacketSend{
						packet = packet,
						node = dst_node,
					})
					fmt.printf("Node %d: here have packet!!\n", node_id)
				} else {
					fmt.printf("Node %d: bad routing rule! discarding packet.\n", node_id)
				}
				continue nextnode
			}
		}

		// the hell is this packet
		fmt.printf("Node %d: the hell is this packet? discarding\n", node_id)
	}

	for send in packet_sends {
		queue.push_back(&send.node.buffer, send.packet)
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

@export
frame :: proc "contextless" (width, height: f32, dt: f32) -> bool {
    context = wasmContext
	defer free_all(context.temp_allocator)

    t += dt

	tick()

    canvas_clear()

	// render padded background
	canvas_rect(pad_size, pad_size, max_width, max_height, 0, 220, 220, 220, 255)

	// render lines
	for i := 0; i < len(conns); i += 1 {
		node_a := nodes[conns[i].src_id.node_id]
		node_b := nodes[conns[i].dst_id.node_id]
		canvas_line(node_a.pos.x + (node_size / 2), node_a.pos.y + (node_size / 2), node_b.pos.x + (node_size / 2), node_b.pos.y + (node_size / 2), 0, 0, 0, 255, 3)
	}

	// render nodes
	for i := 0; i < len(nodes); i += 1 {
    	canvas_rect(nodes[i].pos.x, nodes[i].pos.y, node_size, node_size, 5, 0, 0, 0, 255)

		ip_store := [16]u8{}
		ip_str := ip_to_str(nodes[i].interfaces[0].ip, ip_store[:])
		canvas_text(ip_str, nodes[i].pos.x, nodes[i].pos.y + node_size + 10, 0, 0, 0, 255)
	}

	// render packets
	for i := 0; i < len(conns); i += 1 {
		node_a := nodes[conns[i].src_id.node_id]
		node_b := nodes[conns[i].dst_id.node_id]

		pkt := Packet{pos = node_a.pos}
		a_center := [2]f32{node_a.pos.x + ((node_size / 2) - (packet_size / 2)), node_a.pos.y + ((node_size / 2) - (packet_size / 2))}
		b_center := [2]f32{node_b.pos.x + ((node_size / 2) - (packet_size / 2)), node_b.pos.y + ((node_size / 2) - (packet_size / 2))}

		perc: f32 = 0 // TODO
		lerped := ((1 - perc) * a_center) + (perc * b_center)
		color : f32 = ((-math.cos_f32(t) + 1) / 2) * 255

		canvas_rect(lerped.x, lerped.y, packet_size, packet_size, packet_size / 2, int(color), 100, 100, 255)
	}

    return true
}

@export
temp_allocate :: proc(n: int) -> rawptr {
    context = wasmContext
    return mem.alloc(n, mem.DEFAULT_ALIGNMENT, context.temp_allocator)
}

foreign import "js"

foreign js {
    canvas_clear :: proc() ---
    canvas_clip :: proc(x, y, w, h: f32) ---
    canvas_rect :: proc(x, y, w, h, radius: f32, r, g, b, a: int) ---
    canvas_text :: proc(str: string, x, y: f32, r, g, b, a: int) ---
    canvas_line :: proc(x1, y1, x2, y2: f32, r, g, b, a: int, strokeWidth: f32) ---
    canvas_arc :: proc(x, y, radius, angleStart, angleEnd: f32, r, g, b, a: int, strokeWidth: f32) ---
    measure_text :: proc(str: string) -> f32 ---

    debugger :: proc() ---
    log_string :: proc(str: string) ---
    log_error :: proc(str: string) ---
}
