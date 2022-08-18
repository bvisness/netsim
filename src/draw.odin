package main

import "core:container/queue"
import "core:math"

node_size: f32 : 50
packet_size: f32 : 6
packet_size_in_buffer: f32 : 4
packets_per_row: int : 5

buffer_spacing :: (node_size - 2*packet_size_in_buffer) / f32(packets_per_row-1)

pos_in_buffer :: proc(n: ^Node, i: int) -> Vec2 {
    rect := buffer_rect(n)
    
    row := i / packets_per_row
    col := i % packets_per_row

    offset := Vec2{-1, packet_size_in_buffer + f32(row) * buffer_spacing}
    col_offset := packet_size_in_buffer + f32(col) * buffer_spacing
    if row % 2 == 0 {
        offset.x = col_offset
    } else {
        offset.x = rect.size.x - col_offset
    }

    return rect.pos + offset
}

buffer_rect :: proc(n: ^Node) -> Rect {
    pos := Vec2{n.pos.x, n.pos.y + node_size + 5}
    height: f32 = 0
    if num_packets := queue.len(n.buffer); num_packets > 0 {
        spaces := (num_packets - 1) / packets_per_row
        height = packet_size_in_buffer + f32(spaces)*buffer_spacing + packet_size_in_buffer
    }

    return Rect{
        pos = pos,
        size = Vec2{node_size, height}
    }
}

trapezoid :: proc(t, s1, e1, s2, e2: f32) -> f32 {
    if t <= s1 {
        return 0
    } else if t <= e1 {
        return (t-s1) / (e1-s1)
    } else if t <= s2 {
        return 1
    } else if t <= e2 {
        return 1 - (t-s2) / (e2-s2)
    } else {
        return 0
    }
}

ease_linear :: proc(t, start, end: f32) -> f32 {
    if t <= start {
        return 0
    } else if t >= end {
        return 1
    } else {
        return (t-start) / (end-start)
    }
}

bounce_parabolic :: proc(t: f32) -> f32 {
    return -4 * (t - 0.5) * (t - 0.5) + 1
}

ease_in :: proc(t: f32) -> f32 {
    return 1 - math.cos((t * math.PI) / 2);
}

ease_in_out :: proc(t: f32) -> f32 {
    return -(math.cos(math.PI * t) - 1) / 2;
}

ease_out_elastic :: proc(t: f32) -> f32 {
    c4: f32 = (2 * f32(math.PI)) / 3

    if t == 0 {
        return 0
    } else if t == 1 {
        return 1
    } else {
        return math.pow(2, -10 * t) * math.sin((t * 10 - 0.75) * c4) + 1
    }
}

ease_in_back :: proc(t: f32) -> f32 {
    c1: f32 = 1.70158
    c3: f32 = c1 + 1

    return c3 * t * t * t - c1 * t * t
}
