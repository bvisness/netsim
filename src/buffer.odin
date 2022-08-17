package main

PacketBuffer :: struct {
    data: []Packet,
    
}

buf_peek :: proc(buf: ^PacketBuffer) -> (Packet, bool) {
    if len(buf.data) == 0 {
        return Packet{}, false
    }
    return buf.data[0], true
}

buf_pop :: proc(buf: ^PacketBuffer) -> (Packet, bool) {
    result, ok := buf_peek(buf)
    if ok {
        for i := 1; i < len(buf.data); i += 1 {
            buf.data[i-1] = buf.data[i]
        }
        buf.data = buf.data[:len(buf.data)-1]
    }
    return result, ok
}
