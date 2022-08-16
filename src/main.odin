package main

import "core:fmt"
import "core:math"
import "core:mem"
import "core:runtime"

global_arena_data := [1024]byte{}
global_arena := Arena{}

temp_arena_data := [1024]byte{}
temp_arena := Arena{}

wasmContext := runtime.default_context()

Node :: struct {
	pos: [2]f32,
	iptable: [10]u32,
}

Connection :: struct {
	src: int,
	dst: int,
}

Packet :: struct {
	pos: [2]f32,
	src: u32,
	dst: u32,
}

nodes : [dynamic]Node
conns : [dynamic]Connection

main :: proc() {
    fmt.println("Hellope!")

    arena_init(&global_arena, global_arena_data[:])
    arena_init(&temp_arena, temp_arena_data[:])

    wasmContext.allocator = arena_allocator(&global_arena)
    wasmContext.temp_allocator = arena_allocator(&temp_arena)

    context = wasmContext

	nodes = make([dynamic]Node, 0)
	append(&nodes, Node{pos = {50, 50}})
	append(&nodes, Node{pos = {400, 50}})
	append(&nodes, Node{pos = {400, 400}})
	append(&nodes, Node{pos = {800, 50}})

	conns = make([dynamic]Connection, 0)
	append(&conns, Connection{src = 0, dst = 1})
	append(&conns, Connection{src = 1, dst = 2})
	append(&conns, Connection{src = 1, dst = 3})
}

t: f32 = 0
node_size : f32 = 50
packet_size : f32 = 30

@export
frame :: proc "contextless" (width, height: f32, dt: f32) -> bool {
    context = wasmContext
    t += dt

    canvas_clear()

	for i := 0; i < len(conns); i += 1 {
		node_a := nodes[conns[i].src]
		node_b := nodes[conns[i].dst]
		canvas_line(node_a.pos.x + (node_size / 2), node_a.pos.y + (node_size / 2), node_b.pos.x + (node_size / 2), node_b.pos.y + (node_size / 2), 0, 0, 0, 255, 3)
	}

	for i := 0; i < len(conns); i += 1 {
		node_a := nodes[conns[i].src]
		node_b := nodes[conns[i].dst]

		pkt := Packet{pos = node_a.pos}
		a_center := [2]f32{node_a.pos.x + ((node_size / 2) - (packet_size / 2)), node_a.pos.y + ((node_size / 2) - (packet_size / 2))}
		b_center := [2]f32{node_b.pos.x + ((node_size / 2) - (packet_size / 2)), node_b.pos.y + ((node_size / 2) - (packet_size / 2))}

		perc := ((-math.cos_f32(t) + 1) / 2)
		lerped := ((1 - perc) * a_center) + (perc * b_center)
		color : f32 = ((-math.cos_f32(t) + 1) / 2) * 255

		canvas_rect(lerped.x, lerped.y, packet_size, packet_size, packet_size / 2, int(color), 100, 100, 255)
	}

	for i := 0; i < len(nodes); i += 1 {
    	canvas_rect(nodes[i].pos.x, nodes[i].pos.y, node_size, node_size, 5, 0, 0, 0, 255)
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
