package main

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

	buffer_data: [10]Packet,
	buffer: []Packet,
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

ip_to_str :: proc(ip: u32, ip_store: []u8) -> string {
	b := strings.builder_from_bytes(ip_store[:])

	ip_bytes := transmute([4]u8)ip
	fmt.sbprintf(&b, "%v.%v.%v.%v", ip_bytes[0], ip_bytes[1], ip_bytes[2], ip_bytes[3])

	return strings.to_string(b)
}

str_to_ip :: proc(ip: string) -> (u32, bool) {

	// ip must contain at least 7 chars; ex: `0.0.0.0`
	if len(ip) < 7 {
		return 0, false
	}

	bytes := [4]u8{}
	chunk_idx := 0
	for i := 0; i < len(ip); {

		chunk_len := 0
		chunk : u64 = 0
		chunk_loop: for ; i < len(ip); {
			switch ip[i] {
			case '0'..='9':
				chunk = chunk * 10 + u64(ip[i] - '0')

				i += 1
				chunk_len += 1
			case '.':
				i += 1
				break chunk_loop
			case:
				return 0, false
			}
		}

		// max of 3 digits per chunk, with each section, 255 or less
		if chunk > 255 || chunk_len > 3{
			return 0, false
		}	
		
		bytes[chunk_idx] = u8(chunk)
		chunk_idx += 1
	}

	ip := transmute(u32)bytes
	return ip, true
}

must_str_to_ip :: proc(ip: string) -> u32 {
	ipNum, ok := str_to_ip(ip)
	if !ok {
		intrinsics.trap()
	}
	return ipNum
}

make_node :: proc(pos: Vec2, ip: string) -> Node {
	n := Node{pos = pos}
	n.interfaces[0] = Interface{
		ip = must_str_to_ip(ip),
	}
	n.routing_rules[0] = RoutingRule{
		ip = must_str_to_ip("192.168.1.0"),
		subnet_mask = must_str_to_ip("255.255.255.0"),
		interface_id = 0,
	}
	// TODO: set up buffer slice or whatever
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

	append(&nodes,
		make_node(Vec2{0, 400}, "192.168.1.1"),
		make_node(Vec2{400, 400}, "10.0.0.1"),
		make_node(Vec2{800, 0}, "172.168.1.1"),
		make_node(Vec2{800, 800}, "172.168.1.2"),
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

	append(&conns, Connection{
		src_id = ConnectionID{node_id = 0},
		dst_id = ConnectionID{node_id = 1},
	})
	append(&conns, Connection{
		src_id = ConnectionID{node_id = 1},
		dst_id = ConnectionID{node_id = 2},
	})
	append(&conns, Connection{
		src_id = ConnectionID{node_id = 1},
		dst_id = ConnectionID{node_id = 3},
	})
}

@export
frame :: proc "contextless" (width, height: f32, dt: f32) -> bool {
    context = wasmContext
    t += dt

    canvas_clear()

	// render padded background
	canvas_rect(pad_size, pad_size, max_width, max_height, 0, 220, 220, 220, 255)

	// render lines
	for i := 0; i < len(conns); i += 1 {
		node_a := nodes[conns[i].src_id.node_id]
		node_b := nodes[conns[i].dst_id.node_id]
		canvas_line(node_a.pos.x + (node_size / 2), node_a.pos.y + (node_size / 2), node_b.pos.x + (node_size / 2), node_b.pos.y + (node_size / 2), 0, 0, 0, 255, 3)
	}

	// render packets
	for i := 0; i < len(conns); i += 1 {
		node_a := nodes[conns[i].src_id.node_id]
		node_b := nodes[conns[i].dst_id.node_id]

		pkt := Packet{pos = node_a.pos}
		a_center := [2]f32{node_a.pos.x + ((node_size / 2) - (packet_size / 2)), node_a.pos.y + ((node_size / 2) - (packet_size / 2))}
		b_center := [2]f32{node_b.pos.x + ((node_size / 2) - (packet_size / 2)), node_b.pos.y + ((node_size / 2) - (packet_size / 2))}

		perc := ((-math.cos_f32(t) + 1) / 2)
		lerped := ((1 - perc) * a_center) + (perc * b_center)
		color : f32 = ((-math.cos_f32(t) + 1) / 2) * 255

		canvas_rect(lerped.x, lerped.y, packet_size, packet_size, packet_size / 2, int(color), 100, 100, 255)
	}

	// render nodes
	for i := 0; i < len(nodes); i += 1 {
    	canvas_rect(nodes[i].pos.x, nodes[i].pos.y, node_size, node_size, 5, 0, 0, 0, 255)

		ip_store := [16]u8{}
		ip_str := ip_to_str(nodes[i].interfaces[0].ip, ip_store[:])
		canvas_text(ip_str, nodes[i].pos.x, nodes[i].pos.y + node_size + 10, 0, 0, 0, 255)
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
    logString :: proc(str: string) ---
    logError :: proc(str: string) ---
}
