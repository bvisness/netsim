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
	seq: u32, // SEG.SEQ, the sequence number of the segment
	ack: u32, // SEG.ACK, the sequence number being acknowledged by this segment
	control: TcpControlFlags, // The TCP control bits (SYN, ACK, FIN, etc.)
	wnd: u16, // SEG.WND, the way the receiver communicates the desired size of the send window
}

PacketAnimation :: enum {
	None,
	New,
	Delivered,
	Dropped,
}

TcpControlFlags :: distinct u16

TCP_CWR: TcpControlFlags : 0b10000000
TCP_ECE: TcpControlFlags : 0b01000000
TCP_URG: TcpControlFlags : 0b00100000
TCP_ACK: TcpControlFlags : 0b00010000
TCP_PSH: TcpControlFlags : 0b00001000
TCP_RST: TcpControlFlags : 0b00000100
TCP_SYN: TcpControlFlags : 0b00000010
TCP_FIN: TcpControlFlags : 0b00000001

TcpSession :: struct {
	ip: u32, // we aren't simulating ports, so this uniquely identifies a connection for now...

	state: TcpState,

    // "you just have to track where you're at" -cloin
    snd_una: u32, // SND.UNA, the sequence number of the earliest unacknowledged segment
    snd_nxt: u32, // SND.NXT, the sequence number of the next segment to be sent
    snd_wnd: u16, // SND.WND, the size of the send window (SND.UNA + SND.WND = the send window)
	// no urgent pointers
	snd_wl1: u32, // SND.WL1, the sequence number of the segment that last updated our send window
	snd_wl2: u32, // SND.WL2, the ACK value of the segment that last updated our send window
	iss: u32, // ISS, the Initial Send Sequence number, or the starting point for all our sent segments

	rcv_nxt: u32, // RCV.NXT, the sequence number of the next segment we expect to receive
	rcv_wnd: u16, // RCV.WND, the size of the receive window (RCV.NXT + RCV.WND = the receive window)
	// no urgent pointers
	irs: u32, // IRS, the Initial Receive Sequence Number, or the first sequence number we ACKed
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

control_flag_str :: proc(f: TcpControlFlags) -> string {
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
