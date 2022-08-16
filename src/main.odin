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
}

Packet :: struct {
	pos: [2]f32,
}

main :: proc() {
    fmt.println("Hellope!")

    arena_init(&global_arena, global_arena_data[:])
    arena_init(&temp_arena, temp_arena_data[:])

    wasmContext.allocator = arena_allocator(&global_arena)
    wasmContext.temp_allocator = arena_allocator(&temp_arena)
}

t: f32 = 0

@export
frame :: proc "contextless" (width, height: f32, dt: f32) -> bool {
    context = wasmContext
    t += dt

    canvas_clear()

	me := Node{pos = {50, 50}}
	them := Node{pos = {400, 50}}

	pkt := Packet{pos = me.pos}

	node_size : f32 = 50
	packet_size : f32 = node_size / 2

    canvas_rect(me.pos.x, me.pos.y, node_size, node_size, 5, 0, 0, 0, 255)
    canvas_rect(them.pos.x, them.pos.y, node_size, node_size, 5, 0, 0, 0, 255)
	canvas_line(me.pos.x + node_size, me.pos.y + (node_size / 2), them.pos.x, them.pos.y + (node_size / 2), 0, 0, 0, 255, 3)

	
	me_center := [2]f32{me.pos.x + node_size, me.pos.y + (packet_size / 2)}
	them_center := [2]f32{them.pos.x - packet_size, them.pos.y + (packet_size / 2)}

	perc := ((-math.cos_f32(t) + 1) / 2)
	lerped := ((1 - perc) * me_center) + (perc * them_center)
	canvas_rect(lerped.x, lerped.y, packet_size, packet_size, 5, 100, 100, 100, 255)

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
