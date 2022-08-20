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

foreign import "js"

foreign js {
    canvas_clear :: proc() ---
    canvas_clip :: proc(x, y, w, h: f32) ---
    canvas_rect :: proc(x, y, w, h, radius: f32, r, g, b, a: f32) ---
    canvas_circle :: proc(x, y, radius: f32, r, g, b, a: f32) ---
    canvas_text :: proc(str: string, x, y: f32, r, g, b, a: f32, scale: f32, font: string) ---
    canvas_line :: proc(x1, y1, x2, y2: f32, r, g, b, a: f32, strokeWidth: f32) ---
    canvas_arc :: proc(x, y, radius, angleStart, angleEnd: f32, r, g, b, a: f32, strokeWidth: f32) ---
    measure_text :: proc(str: string, scale: f32, font: string) -> f32 ---
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
draw_text :: proc(str: string, pos: Vec2, scale: f32, font: string, color: Vec3, a: f32 = 255) {
    canvas_text(str, pos.x, pos.y, color.x, color.y, color.z, a, scale, font)
}
draw_line :: proc(start, end: Vec2, strokeWidth: f32, color: Vec3, a: f32 = 255) {
    canvas_line(start.x, start.y, end.x, end.y, color.x, color.y, color.z, a, strokeWidth)
}
draw_arc :: proc(center: Vec2, radius, angleStart, angleEnd: f32, strokeWidth: f32, color: Vec3, a: f32) {
    canvas_arc(center.x, center.y, radius, angleStart, angleEnd, color.x, color.y, color.z, a, strokeWidth)
}

scaled_rect :: proc(x, y, width, height, radius, r, g, b, a: f32) {
	canvas_rect((x * scale) + pan.x, (y * scale) + pan.y, width * scale, height * scale, radius * scale, r, g, b, a)
}
scaled_circle :: proc(x, y, size, r, g, b, a: f32) {
	canvas_circle((x * scale) + pan.x, (y * scale) + pan.y, size * scale, r, g, b, a)
}
scaled_line :: proc(x1, y1, x2, y2, r, g, b, a, width: f32) {
	canvas_line((x1 * scale) + pan.x, (y1 * scale) + pan.y, (x2 * scale) + pan.x, (y2 * scale) + pan.y, r, g, b, a, width * scale)
}
scaled_text :: proc(text: string, x, y: f32, font: string, r, g, b, a: f32) {
	canvas_text(text, (x * scale) + pan.x, (y * scale) + pan.y, r, g, b, a, scale, font)
}
