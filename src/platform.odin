package main

import "core:mem"
import "core:runtime"

@export
mouse_move :: proc "contextless" (x, y: int) {
	last_mouse_pos = mouse_pos
	mouse_pos = Vec2{f32(x), f32(y)}
}

@export
mouse_down :: proc "contextless" (x, y: int) {
	is_mouse_down = true
	last_mouse_pos = mouse_pos
	mouse_pos = Vec2{f32(x), f32(y)}
}

@export
mouse_up :: proc "contextless" (x, y: int) {
	is_mouse_down = false
	last_mouse_pos = mouse_pos
	mouse_pos = Vec2{f32(x), f32(y)}
}

@export
scroll :: proc "contextless" (x, y: int) {
	scroll_velocity = f32(y)
}

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
    canvas_text :: proc(str: string, x, y: f32, r, g, b, a: f32, scale: f32) ---
    canvas_line :: proc(x1, y1, x2, y2: f32, r, g, b, a: f32, strokeWidth: f32) ---
    canvas_arc :: proc(x, y, radius, angleStart, angleEnd: f32, r, g, b, a: f32, strokeWidth: f32) ---
    measure_text :: proc(str: string) -> f32 ---
    play_tone :: proc(freq: f32) ---

    debugger :: proc() ---
    log_string :: proc(str: string) ---
    log_error :: proc(str: string) ---
}

draw_rect :: proc(rect: Rect, radius: f32, color: Vec3, a: f32 = 255) {
    canvas_rect(rect.pos.x, rect.pos.y, rect.size.x, rect.size.y, radius, color.x, color.y, color.z, a)
}
draw_circle :: proc(center: Vec2, radius: f32, color: Vec3, a: f32 = 255) {
    canvas_circle(center.x, center.y, radius, color.x, color.y, color.z, a)
}
draw_text :: proc(str: string, pos: Vec2, scale: f32, color: Vec3, a: f32 = 255) {
    canvas_text(str, pos.x, pos.y, color.x, color.y, color.z, a, scale)
}
draw_line :: proc(start, end: Vec2, strokeWidth: f32, color: Vec3, a: f32 = 255) {
    canvas_line(start.x, start.y, end.x, end.y, color.x, color.y, color.z, a, strokeWidth)
}
draw_arc :: proc(center: Vec2, radius, angleStart, angleEnd: f32, strokeWidth: f32, color: Vec3, a: f32, ) {
    canvas_arc(center.x, center.y, radius, angleStart, angleEnd, color.x, color.y, color.z, a, strokeWidth)
}
