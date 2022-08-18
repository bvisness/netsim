package main

import "core:mem"
import "core:runtime"

@export
mouse_move :: proc "contextless" (x, y: int) {}

@export
mouse_down :: proc "contextless" (x, y: int) {}

@export
mouse_up :: proc "contextless" (x, y: int) {}

@export
scroll :: proc "contextless" (x, y: int) {}

@export
key_down :: proc "contextless" (key: int) {}

@export
key_up :: proc "contextless" (key: int) {}

@export
text_input :: proc "contextless" () {}

@export
blur :: proc "contextless" () {}

@export
temp_allocate :: proc(n: int) -> rawptr {
    context = wasmContext
    return mem.alloc(n, mem.DEFAULT_ALIGNMENT, context.temp_allocator)
}

// what a hilarious program LLVM is
ordered_remove :: proc(array: ^$D/[dynamic]$T, index: int, loc := #caller_location) #no_bounds_check {
	runtime.bounds_check_error_loc(loc, index, len(array))
	for i := index+1; i < len(array); i += 1 {
		array[i-1] = array[i]
	}
	(^runtime.Raw_Dynamic_Array)(array).len -= 1
}

foreign import "js"

foreign js {
    canvas_clear :: proc() ---
    canvas_clip :: proc(x, y, w, h: f32) ---
    canvas_rect :: proc(x, y, w, h, radius: f32, r, g, b, a: f32) ---
    canvas_circle :: proc(x, y, radius: f32, r, g, b, a: f32) ---
    canvas_text :: proc(str: string, x, y: f32, r, g, b, a: f32) ---
    canvas_line :: proc(x1, y1, x2, y2: f32, r, g, b, a: f32, strokeWidth: f32) ---
    canvas_arc :: proc(x, y, radius, angleStart, angleEnd: f32, r, g, b, a: f32, strokeWidth: f32) ---
    measure_text :: proc(str: string) -> f32 ---
    play_tone :: proc(freq: f32) ---

    debugger :: proc() ---
    log_string :: proc(str: string) ---
    log_error :: proc(str: string) ---
}
