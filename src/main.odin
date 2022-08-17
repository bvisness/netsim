package main

import "core:container/queue"
import "core:encoding/json"
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

Vec2 :: distinct [2]f32

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
}

nodes : [dynamic]Node
conns : [dynamic]Connection

t: f32 = 0
min_width   : f32 = 10000
min_height  : f32 = 10000
max_width   : f32 = 0
max_height  : f32 = 0
pad_size    : f32 = 40
node_size   : f32 = 50
packet_size : f32 = 30
buffer_size : int = 10
TICK_INTERVAL_S :: 0.2

net_config := `
{
	"nodes": [
		{
			"name": "me",
			"pos": { "x": 0, "y": 400 },
			"interfaces": [ "2.2.2.123" ],
			"rules": [
				{ "ip": "0.0.0.0", "subnet": "0.0.0.0", "interface": 0 }
			]
		},
		{
			"name": "comcast",
			"pos": { "x": 200, "y": 400 },
			"interfaces": [ "2.2.2.1", "2.2.2.2", "2.2.2.3" ],
			"rules": [
				{ "ip": "2.2.2.123", "subnet": "255.255.255.255", "interface": 0 },
				{ "ip": "3.0.0.0",   "subnet": "255.0.0.0",       "interface": 1 },
				{ "ip": "4.0.0.0",   "subnet": "255.0.0.0",       "interface": 2 },
				{ "ip": "5.0.0.0",   "subnet": "255.0.0.0",       "interface": 2 }
			]
		},
		{
			"name": "google",
			"pos": { "x": 400, "y": 200 },
			"interfaces": [ "3.3.3.1", "3.3.3.2" ],
			"rules": [
				{ "ip": "2.0.0.0", "subnet": "255.0.0.0", "interface": 0 },
				{ "ip": "4.0.0.0", "subnet": "255.0.0.0", "interface": 1 },
				{ "ip": "5.0.0.0", "subnet": "255.0.0.0", "interface": 1 }
			]
		},
		{
			"name": "cloudflare",
			"pos": { "x": 400, "y": 600 },
			"interfaces": [ "4.4.4.1", "4.4.4.2", "4.4.4.3" ],
			"rules": [
				{ "ip": "2.0.0.0", "subnet": "255.0.0.0", "interface": 0 },
				{ "ip": "3.0.0.0", "subnet": "255.0.0.0", "interface": 1 },
				{ "ip": "5.0.0.0", "subnet": "255.0.0.0", "interface": 2 }
			]
		},
		{
			"name": "discord_hub",
			"pos": { "x": 600, "y": 600 },
			"interfaces": [ "5.5.5.1", "5.5.5.2", "5.5.5.2", "5.5.5.2" ],
			"rules": [
				{ "ip": "4.0.0.0",   "subnet": "255.0.0.0",       "interface": 0 },
				{ "ip": "5.5.100.1", "subnet": "255.255.255.255", "interface": 1 },
				{ "ip": "5.5.100.2", "subnet": "255.255.255.255", "interface": 2 },
				{ "ip": "5.5.100.3", "subnet": "255.255.255.255", "interface": 3 },
			]
		},
		{
			"name": "discord_1",
			"pos": { "x": 750, "y": 500 },
			"interfaces": [ "5.5.100.1" ],
			"rules": [
				{ "ip": "0.0.0.0", "subnet": "0.0.0.0", "interface": 0 },
			]
		},
		{
			"name": "discord_2",
			"pos": { "x": 750, "y": 600 },
			"interfaces": [ "5.5.100.2" ],
			"rules": [
				{ "ip": "0.0.0.0", "subnet": "0.0.0.0", "interface": 0 },
			]
		},
		{
			"name": "discord_3",
			"pos": { "x": 750, "y": 700 },
			"interfaces": [ "5.5.100.3" ],
			"rules": [
				{ "ip": "0.0.0.0", "subnet": "0.0.0.0", "interface": 0 },
			]
		}
	],
	"conns": [
		{
			"name": "me_comcast",
			"src": { "node_id": 0, "interface_id": 0 },
			"dst": { "node_id": 1, "interface_id": 0 }
		},
		{
			"name": "comcast_google",
			"src": { "node_id": 1, "interface_id": 1 },
			"dst": { "node_id": 2, "interface_id": 0 }
		},
		{
			"name": "comcast_cloudflare",
			"src": { "node_id": 1, "interface_id": 2 },
			"dst": { "node_id": 3, "interface_id": 0 }
		},
		{
			"name": "google_cloudflare",
			"src": { "node_id": 2, "interface_id": 1 },
			"dst": { "node_id": 3, "interface_id": 1 }
		},
		{
			"name": "cloudflare_discord_hub",
			"src": { "node_id": 3, "interface_id": 2 },
			"dst": { "node_id": 4, "interface_id": 0 }
		},
		{
			"name": "discord_hub_discord_1",
			"src": { "node_id": 4, "interface_id": 1 },
			"dst": { "node_id": 5, "interface_id": 0 }
		},
		{
			"name": "discord_hub_discord_2",
			"src": { "node_id": 4, "interface_id": 2 },
			"dst": { "node_id": 6, "interface_id": 0 }
		},
		{
			"name": "discord_hub_discord_3",
			"src": { "node_id": 4, "interface_id": 3 },
			"dst": { "node_id": 7, "interface_id": 0 }
		}
	]
}
`

make_node :: proc(pos: Vec2, name: string, interfaces: []Interface, routing_rules: []RoutingRule) -> Node {
	n := Node{pos = pos}

	n.name = name
	n.interfaces = interfaces
	n.routing_rules = routing_rules

	if ok := queue.init(&n.buffer, buffer_size); !ok {
		fmt.println("Successfully failed to init queue.")
		intrinsics.trap()
	}
	return n
}

load_config :: proc(config: string, nodes: ^[dynamic]Node, conns: ^[dynamic]Connection) -> bool {
	blah, err := json.parse(transmute([]u8)config, json.DEFAULT_SPECIFICATION, true)
	if err != nil {
		fmt.printf("%s\n", err)
		return false
	}
	obj_map := blah.(json.Object) or_return

	// parse nodes
	nodes_obj := obj_map["nodes"].(json.Array) or_return
	for v in nodes_obj {
		obj := v.(json.Object) or_return

		name := obj["name"].(string) or_return

		pos_map := obj["pos"].(json.Object) or_return

		x := pos_map["x"].(i64) or_return
		y := pos_map["y"].(i64) or_return
		pos := Vec2{f32(x), f32(y)}

		interfaces := make([dynamic]Interface)
		interfaces_arr := obj["interfaces"].(json.Array) or_return
		for interface in interfaces_arr {
			ip_str := interface.(string) or_return
			ip := str_to_ip(ip_str) or_return

			append(&interfaces, Interface{ip = ip})
		}

		rules := make([dynamic]RoutingRule)
		rules_arr := obj["rules"].(json.Array) or_return
		for rule_obj in rules_arr {
			rule := rule_obj.(json.Object) or_return

			ip_str := rule["ip"].(string) or_return
			ip := str_to_ip(ip_str) or_return

			subnet_str := rule["subnet"].(string) or_return
			subnet_mask := str_to_ip(subnet_str) or_return

			interface := rule["interface"].(i64) or_return

			append(&rules, RoutingRule{ip = ip, subnet_mask = subnet_mask, interface_id = int(interface)})
		}

		append(nodes, make_node(pos, name, interfaces[:], rules[:]))
	}

	// parse connections
	conns_obj := obj_map["conns"].(json.Array) or_return
	for v in conns_obj {
		obj := v.(json.Object) or_return

		src_map := obj["src"].(json.Object) or_return
		src_node_id := src_map["node_id"].(i64) or_return
		src_interface_id := src_map["interface_id"].(i64) or_return

		dst_map := obj["dst"].(json.Object) or_return
		dst_node_id := dst_map["node_id"].(i64) or_return
		dst_interface_id := dst_map["interface_id"].(i64) or_return

		append(conns, Connection{
			src_id = ConnectionID{node_id = int(src_node_id), interface_id = int(src_interface_id)},
			dst_id = ConnectionID{node_id = int(dst_node_id), interface_id = int(dst_interface_id)},
		})
	}

	return true
}

main :: proc() {
    arena_init(&global_arena, global_arena_data[:])
    arena_init(&temp_arena, temp_arena_data[:])

    wasmContext.allocator = arena_allocator(&global_arena)
    wasmContext.temp_allocator = arena_allocator(&temp_arena)

    context = wasmContext

	nodes = make([dynamic]Node)
	conns = make([dynamic]Connection)

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
			// fmt.printf("Node %d: thank you for the packet in these trying times\n", node_id)
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
					// fmt.printf("Node %d: here have packet!!\n", node_id)
				} else {
					// fmt.printf("Node %d: bad routing rule! discarding packet.\n", node_id)
				}
				continue nextnode
			}
		}

		// the hell is this packet
		// fmt.printf("Node %d: the hell is this packet? discarding\n", node_id)
	}

	for send in packet_sends {
		if queue.len(send.node.buffer) >= buffer_size {
			// fmt.printf("Buffer full, packet dropped\n")
			continue
		}

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
					src_ip = nodes[src_id].interfaces[0].ip,
					dst_ip = nodes[dst_id].interfaces[0].ip,
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
	for node in nodes {
    	canvas_rect(node.pos.x, node.pos.y, node_size, node_size, 5, 0, 0, 0, 255)

		ip_pad : f32 = 5 
		ip_offset : f32 = 16
		for interface, i in node.interfaces {
			ip_store := [16]u8{}
			ip_str := ip_to_str(interface.ip, ip_store[:])
			canvas_text(ip_str, node.pos.x, node.pos.y + node_size + ip_pad + (ip_offset * f32(i)), 0, 0, 0, 255)
		}

		canvas_text(fmt.tprintf("%s [%d]", node.name, queue.len(node.buffer)), node.pos.x, node.pos.y - 16, 0, 0, 0, 255)

		if queue.len(node.buffer) > 0 {
			pos := Vec2{node.pos.x + ((node_size / 2) - (packet_size / 2)), node.pos.y + ((node_size / 2) - (packet_size / 2))}
			color : f32 = ((-math.cos_f32(t) + 1) / 2) * 255

			canvas_rect(pos.x, pos.y, packet_size, packet_size, packet_size / 2, int(color), 100, 100, 255)
		}
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
