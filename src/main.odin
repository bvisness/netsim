package main

import "core:fmt"
import "core:mem"
import "core:runtime"

global_arena_data := [1024]byte{}
global_arena := Arena{}

temp_arena_data := [1024]byte{}
temp_arena := Arena{}

wasmContext := runtime.default_context()

main :: proc() {
    fmt.println("Hellope!")

    arena_init(&global_arena, global_arena_data[:])
    arena_init(&temp_arena, temp_arena_data[:])

    wasmContext.allocator = arena_allocator(&global_arena)
    wasmContext.temp_allocator = arena_allocator(&temp_arena)
}

@export
frame :: proc "contextless" () {}

@export
temp_allocate :: proc(n: int) -> rawptr {
    context = wasmContext
    return mem.alloc(n, mem.DEFAULT_ALIGNMENT, context.temp_allocator)
}

foreign import "js"

foreign js {
    canvas_clear :: proc() ---
    canvas_clip :: proc(x, y, w, h: int) ---
    canvas_rect :: proc(x, y, w, h, r, red, green, blue, alpha: int) ---
    canvas_text :: proc(str: string, x, y, r, g, b, a: int) ---
    canvas_line :: proc(x1, y1, x2, y2, r, g, b, a: int, strokeWidth: f32) ---
    canvas_arc :: proc(x, y, radius: int, angleStart, angleEnd: f32, r, g, b, a: int, strokeWidth: f32) ---
    measure_text :: proc(str: string) -> int ---

    debugger :: proc() ---
    logString :: proc(str: string) ---
    logError :: proc(str: string) ---
}
