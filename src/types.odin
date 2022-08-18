package main

import "core:container/queue"

Vec2 :: [2]f32
Vec3 :: [3]f32
Rect :: struct {
	pos: Vec2,
	size: Vec2,
}

Node :: struct {
	pos: Vec2,

	name: string,
	interfaces: []Interface,
	routing_rules: []RoutingRule,

	buffer: queue.Queue(Packet),
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

	// TCP properties
	sequence_number: u32,
	ack_number: u32,
	tcp_flags: u16,
	window_size: u16,

	// Properties for visualization
	pos: Vec2,
	last_pos: Vec2,
	color: Vec3,
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

PacketType :: enum {
	Unknown,
	UDP,
	TCP,
}

PacketAnimation :: enum {
	None,
	New,
	Delivered,
	Dropped,
}

TCP_NS  :: 0b100000000
TCP_CWR :: 0b010000000
TCP_ECE :: 0b001000000
TCP_URG :: 0b000100000
TCP_ACK :: 0b000010000
TCP_PSH :: 0b000001000
TCP_RST :: 0b000000100
TCP_SYN :: 0b000000010
TCP_FIN :: 0b000000001

TcpSession :: struct {
    // "you just have to track where you're at" -cloin

    send_unacknowledged: u32,
    send_next: u32,
    send_window: u32,
}