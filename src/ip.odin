package main

import "core:fmt"
import "core:intrinsics"
import "core:strings"

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
