package main

import "core:container/queue"
import "core:intrinsics"
import "core:fmt"

Vec2 :: [2]f32
Vec3 :: [3]f32
Rect :: struct {
	pos: Vec2,
	size: Vec2,
}

InputField :: struct {
	has_focus: bool,
	cursor: int,
	alpha: f32,
	buffer: [1024]u8,
	max_size: int,
}

make_input_field :: proc(max_size: int) -> InputField {
	return InputField {
		has_focus = false,
		cursor = 0,
		alpha = 255,
		max_size = max_size,
	}
}

get_current_field :: proc() -> (int, bool) {
	for input, idx in &inputs {
		if input.has_focus {
			return idx, true
		}
	}

	return 0, false
}

Node :: struct {
	logs: queue.Queue(LogEntry), // DO NOT MOVE ELSEWHERE IN THE STRUCT

	pos: Vec2,

	name: string,
	interfaces: []Interface,
	routing_rules: []RoutingRule,
	packets_per_tick: int,
	max_buffer_size: int,

	sent: u64,
	old_sent: u64,

	received: u64,
	old_received: u64,

	dropped: u64,
	old_dropped: u64,

	avg_tick_history: queue.Queue(u32),
	avg_recv_history: queue.Queue(u32),
	avg_sent_history: queue.Queue(u32),
	avg_drop_history: queue.Queue(u32),

	buffer: queue.Queue(Packet),

	listening: bool,
	tcp_sessions: [dynamic]TcpSession,
}

LogEntry :: struct {
	timestamp: int,
	content: string,
}

Interface :: struct {
	ip: u32,

	// stats?
	// buffers?
}

RoutingRule :: struct {
	ip: u32, 
	subnet_mask: u32,
	interface_id: int,
}

Connection :: struct {
	src_id: ConnectionID,
	dst_id: ConnectionID,

	loss_factor: f32, // 0 = no loss, 1 = all packets are dropped
}

ConnectionID :: struct {
	node_id: int,
	interface_id: int,
}

Packet :: struct {
	src_ip: u32,
	dst_ip: u32,
	
	ttl: u32,
	tick_life: u32,

	protocol: PacketProtocol,
	tcp: PacketTcp,
	data: string,

	//
	// Properties for visualization
	//

	pos: Vec2,
	last_pos: Vec2,
	color: ^Vec3,
	anim: PacketAnimation,
	// NOTE(ben): If / when we add node deletion, this could get into use-after-free territory.
	// Maybe avoid it by not allowing editing while simulating...
	src_node: ^Node,
	dst_node: ^Node,
	src_bufid: int,
	dst_bufid: int,

	created_t: f32, // when this transitioned to New
	delivered_t: f32,
	dropped_t: f32,
	velocity: Vec2, // for dropping
	drop_at_dst: bool,
	initialized_drop_at_dst: bool,
}

PacketProtocol :: enum {
	Unknown,
	UDP,
	TCP,
}

PacketTcp :: struct  {
	sequence_number: u32,
	ack_number: u32,
	control_flags: u16,
	window: u16,
}

PacketAnimation :: enum {
	None,
	New,
	Delivered,
	Dropped,
}

TCP_CWR :: 0b10000000
TCP_ECE :: 0b01000000
TCP_URG :: 0b00100000
TCP_ACK :: 0b00010000
TCP_PSH :: 0b00001000
TCP_RST :: 0b00000100
TCP_SYN :: 0b00000010
TCP_FIN :: 0b00000001

TcpSession :: struct {
	ip: u32, // we aren't simulating ports, so this uniquely identifies a connection for now...

	state: TcpState,

    // "you just have to track where you're at" -cloin
    send_unacknowledged: u32, // SND.UNA
    send_next: u32,	// SND.NXT
    send_window: u16, // SND.WND
	// no urgent pointers
	last_window_update_seq_num: u32, // SND.WL1
	last_window_update_ack_num: u32, // SND.WL2
	initial_send_seq_num: u32, // ISS

	receive_next: u32, // RCV.NXT
	receive_window: u16, // RCV.WND
	// no urgent pointers
	initial_receive_seq_num: u32, // IRS
}

TcpState :: enum {
	Closed,
	Listen,
	SynSent,
	SynReceived,
	Established,
	FinWait1,
	FinWait2,
	CloseWait,
	Closing,
	LastAck,
	TimeWait,
}

make_node :: proc(
	pos: Vec2,
	name: string,
	interfaces: []Interface,
	routing_rules: []RoutingRule,
	packets_per_tick: int,
	max_buffer_size: int,
) -> Node {
	n := Node{
		pos = pos,
		name = name,
		interfaces = interfaces,
		routing_rules = routing_rules,
		packets_per_tick = packets_per_tick,
		max_buffer_size = max_buffer_size,
	}

	n.tcp_sessions = make([dynamic]TcpSession)

	if ok := queue.init(&n.buffer, max_buffer_size); !ok {
		fmt.println("Successfully failed to init packet queue.")
		intrinsics.trap()
	}

	if ok := queue.init(&n.avg_tick_history, history_size); !ok {
		fmt.println("Successfully failed to init stat queue.")
		intrinsics.trap()
	}
	if ok := queue.init(&n.avg_recv_history, history_size); !ok {
		fmt.println("Successfully failed to init stat queue.")
		intrinsics.trap()
	}
	if ok := queue.init(&n.avg_sent_history, history_size); !ok {
		fmt.println("Successfully failed to init stat queue.")
		intrinsics.trap()
	}
	if ok := queue.init(&n.avg_drop_history, history_size); !ok {
		fmt.println("Successfully failed to init stat queue.")
		intrinsics.trap()
	}
	if ok := queue.init(&n.logs, log_size); !ok {
		fmt.println("Successfully failed to init log queue.")
		intrinsics.trap()
	}

	return n
}

node_log :: proc(n: ^Node, msg: string) {
	if queue.len(n.logs) > log_size {
		queue.pop_front(&n.logs)
	}

	queue.push_back(&n.logs, LogEntry{tick_count, msg})
}

control_flag_str :: proc(f: u16) -> string {
	if f&TCP_SYN != 0 && f&TCP_ACK != 0 {
		return "SYNACK"
	} else if f&TCP_RST != 0 && f&TCP_ACK != 0 {
		return "RST / ACK"
	} else if f&TCP_SYN != 0 {
		return "SYN"
	} else if f&TCP_ACK != 0 {
		return "ACK"
	} else if f&TCP_RST != 0 {
		return "RST"
	} else {
		return "???"
	}
}

rect :: proc(x, y, w, h: f32) -> Rect {
	return Rect{Vec2{x, y}, Vec2{w, h}}
}
