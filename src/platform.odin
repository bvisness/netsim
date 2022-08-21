package main

import "core:mem"
import "core:runtime"
import "core:fmt"

@export
set_text_height :: proc "contextless" (height: f32) {
	text_height = height
	line_gap = height + (height * (3/4))
}

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

shift_down := false
@export
key_down :: proc "contextless" (key: int) {
	context = wasmContext

	switch key {
	case 1: // left-shift
		shift_down = true
	case 4096: // tab
		if infield_idx, ok := get_current_field(); ok {
			new_idx: int
			if shift_down {
				new_idx = (infield_idx - 1) %% len(inputs)
			} else {
				new_idx = (infield_idx + 1) %% len(inputs)
			}

			inputs[infield_idx].has_focus = false
			inputs[new_idx].has_focus = true
		}
	case 8: // backspace
		infield_idx, ok := get_current_field()
		if ok {
			infield := &inputs[infield_idx]
			infield.cursor -= 1
			infield.cursor = max(infield.cursor, 0)
			infield.buffer[infield.cursor] = 0
		}
	}
}

@export
key_up :: proc "contextless" (key: int) {
	switch key {
	case 1: // left-shift
		shift_down = false
	}
}

@export
text_input :: proc "contextless" (key, code: string) {
	context = wasmContext

	switch code {
	case "Space":
		infield_idx, ok := get_current_field()
		if ok {
			infield := &inputs[infield_idx]
			if infield.cursor < infield.max_size {
				infield.buffer[infield.cursor] = key[0]
				infield.cursor += 1
			}
		} else {
			running = !running
		}
	case: // *should* be character keys
		infield_idx, ok := get_current_field()
		if ok {
			infield := &inputs[infield_idx]
			if infield.cursor < infield.max_size {
				infield.buffer[infield.cursor] = key[0]
				infield.cursor += 1
			}
		}
	}
}

@export
blur :: proc "contextless" () {}

@export
temp_allocate :: proc(n: int) -> rawptr {
    context = wasmContext
    return mem.alloc(n, mem.DEFAULT_ALIGNMENT, context.temp_allocator)
}

// This is gross..
@export
loaded_session_result :: proc "contextless" (key, val: string) {
	switch key {
	case "muted":
		muted = (val == "true")
	}
}

@export
load_build_hash :: proc "contextless" (_hash: int) {
	hash = _hash
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
    get_text_height :: proc(scale: f32, font: string) -> f32 ---

    debugger :: proc() ---
    log_string :: proc(str: string) ---
    log_error :: proc(str: string) ---

    play_tone :: proc(freq: f32) ---
	get_session_storage :: proc(key: string) ---
	set_session_storage :: proc(key: string, val: string) ---
	get_time :: proc() -> f64 ---
	change_cursor :: proc(cursor: string) ---
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

draw_rect_outline :: proc(rect: Rect, width: f32, color: Vec3, a: f32 = 255) {
	x1 := rect.pos.x
	y1 := rect.pos.y
	x2 := rect.pos.x + rect.size.x
	y2 := rect.pos.y + rect.size.y

	draw_line(Vec2{x1, y1}, Vec2{x2, y1}, width, color, a)
	draw_line(Vec2{x1, y1}, Vec2{x1, y2}, width, color, a)
	draw_line(Vec2{x2, y1}, Vec2{x2, y2}, width, color, a)
	draw_line(Vec2{x1, y2}, Vec2{x2, y2}, width, color, a)
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

play_doot :: proc() {
	if muted {
		return
	}

	tones := []f32{ 392, 440, 493.88, 523.25, 587.33, 659.25, 739.99 }
	idx := rand_int(0, len(tones) - 1)
	play_tone(tones[idx])
}

set_cursor :: proc(cursor: string) {
	change_cursor(cursor)
	is_hovering = true
}

reset_cursor :: proc() {
	change_cursor("auto")
}
