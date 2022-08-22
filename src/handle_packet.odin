package main

import "core:container/queue"
import "core:fmt"
import "core:math/rand"
import "core:sort"
import "core:strings"

SEG_SIZE :: 10
RETRANSMIT_TIMEOUT :: 25 // ticks
RETRANSMIT_JITTER :: 10 // more ticks
SSTHRESH :: 8*SEG_SIZE // bytes
GLOBAL_TIMEOUT :: 45 // ticks
ack_delay := 5 // ticks

COLOR_RST    := Vec3{220, 80, 80}
COLOR_SYN    := Vec3{80, 80, 220}
COLOR_ACK    := Vec3{80, 220, 80}
COLOR_SYNACK := Vec3{80, 220, 220}

handle_packet :: proc(n: ^Node, p: Packet) {
    #partial switch p.protocol {
    case .TCP:
        handle_tcp_packet(n, p)
    }
}

// This closely follows the absolutely indispensable implementation guide in
// RFC 9293, specifically the "Event Processing" section:
//
// https://www.rfc-editor.org/rfc/rfc9293.html#name-event-processing
handle_tcp_packet :: proc(n: ^Node, p: Packet) {
    node_log(n, "Incoming packet:")
    node_log_tcp_packet(n, p)

    sess_idx, ok := get_tcp_session(n, p.src_ip)
    if !ok && !n.listening {
        // CLOSED state (3.10.7.1)

        // RSTs are ignored while closed; we're already closed.
        if p.tcp.control&TCP_RST != 0 {
            return
        }

        // Any other packet causes a RST to be sent in return. The details of
        // the sequence and ack numbers are weird and I just trust the spec.
        if p.tcp.control&TCP_ACK == 0 {
            node_log(n, "Received a packet while closed (case 1).")
            send_packet(n, Packet{
                dst_ip = p.src_ip,
                protocol = PacketProtocol.TCP,
                tcp = PacketTcp{
                    seq = 0,
                    ack = p.tcp.seq + u32(len(p.data)),
                    control = TCP_RST|TCP_ACK,
                },
                color = &COLOR_RST,
            })
        } else {
            node_log(n, "Received a packet while closed (case 2).")
            send_packet(n, Packet{
                dst_ip = p.src_ip,
                protocol = PacketProtocol.TCP,
                tcp = PacketTcp{
                    seq = p.tcp.ack,
                    control = TCP_RST,
                },
                color = &COLOR_RST,
            })
        }
        return
    } else if !ok && n.listening {
        // LISTEN state (3.10.7.2)

        // RSTs are ignored; they could not possibly be relevant since we haven't sent anything.
        if p.tcp.control&TCP_RST != 0 {
            return
        }

        // ACKs are no good if we're in LISTEN; we haven't sent anything to be ACKed!
        // Send a RST.
        if p.tcp.control&TCP_ACK != 0 {
            send_packet(n, Packet{
                dst_ip = p.src_ip,
                protocol = PacketProtocol.TCP,
                tcp = PacketTcp{
                    seq = p.tcp.ack,
                    control = TCP_RST,
                },
                color = &COLOR_RST,
            })
            return
        }

        // SYNs mean we're starting up a new connection.
        if p.tcp.control&TCP_SYN != 0 {
            sess_idx, ok := new_tcp_session(n, p.src_ip)
            if !ok {
                // Out of resources! Die.
                return
            }
			sess := &n.tcp_sessions[sess_idx]

            // No security concerns here.

            sess.irs = p.tcp.seq
            sess.rcv_nxt = p.tcp.seq + 1

            // TODO: Queue any data in this packet to be processed later.
            // The sender can include data in the initial SYN packet.

            sess.iss = tcp_initial_sequence_num()
            send_packet(n, Packet{
                dst_ip = p.src_ip,
                protocol = PacketProtocol.TCP,
                tcp = PacketTcp{
                    seq = sess.iss,
                    ack = sess.rcv_nxt,
                    control = TCP_SYN|TCP_ACK,
                    wnd = sess.rcv_wnd,
                },
                color = &COLOR_SYNACK,
            })

            sess.snd_una = sess.iss
            sess.snd_nxt = sess.iss + 1

            node_log(n, "Moving from LISTEN to SYN-RECEIVED")
            sess.state = TcpState.SynReceived

            // Maybe in the future handle other control codes here?

            return
        }

        // This should never be reached. Well-behaved TCP packets would have
        // been caught by one of the above cases. Of course, this is a sim, so
        // it will probably happen a lot :)
        return
    }
	sess := &n.tcp_sessions[sess_idx]

    // Now, on to the actual session states...
    assert(sess != nil)

    if sess.state == TcpState.SynSent {
        // SYN-SENT (3.10.7.3)

        is_syn := p.tcp.control&TCP_SYN != 0
        is_ack := p.tcp.control&TCP_ACK != 0
        is_rst := p.tcp.control&TCP_RST != 0

        // Handle an ACK, specifically a bad one. Since we sent the initial
        // SYN, we're expecting an ACK back, but also expecting a SYN. All the
        // good behavior is handled later on.
        if is_ack {
            // All ACKs must be for data in our unacknowledged window; that is,
            // between the last un-ACKed seq number and the next one we're gonna
            // send. Anything outside this triggers a RST.
            bad_ack := p.tcp.ack <= sess.iss || p.tcp.ack > sess.snd_nxt // TODO(mod)
            if bad_ack {
                if is_rst {
                    return // Don't RST a RST.
                }

                node_log(n, fmt.aprintf("Got a bad ACK in SYN-SENT:"))
                node_log_tcp_state(n, sess)
                send_packet(n, Packet{
                    dst_ip = p.src_ip,
                    protocol = PacketProtocol.TCP,
                    tcp = PacketTcp{
                        seq = p.tcp.ack,
                        control = TCP_RST,
                    },
                    color = &COLOR_RST,
                })
                return
            }
        }

        // Handle a RST
        if is_rst {
            if is_ack {
                // It must be a good ACK, or we would have caught it earlier.
                // That means the RST was intended for us and we should close
                // our connection.
                node_log(n, "Got a RST while handshaking. Closing connection.")
                close_tcp_session(n, sess)
            }
            return
        }

        // No security checks.

        // At this point, we either have a good ACK or no ACK at all.

        // Handle a SYN, and maybe a SYNACK
        if is_syn {
            sess.irs = p.tcp.seq
            sess.rcv_nxt = p.tcp.seq + 1
            if is_ack {
                tcp_track_ack(n, sess, p.tcp.ack)
            }

            if sess.snd_una > sess.iss {
                // The SYN we sent has been ACKed, plus we got a SYN in return.
                // We can ACK back, and at this point we're established.
                node_log(n, "Our SYN has been ACKed. Moved from SYN-SENT to ESTABLISHED.")
                sess.state = TcpState.Established
                send_packet(n, Packet{
                    dst_ip = p.src_ip,
                    protocol = PacketProtocol.TCP,
                    tcp = PacketTcp{
                        seq = sess.snd_nxt,
                        ack = sess.rcv_nxt,
                        control = TCP_ACK,
                        wnd = sess.rcv_wnd,
                    },
                    color = &COLOR_ACK,
                })

                // TODO(ben): I don't think the spec explicitly told me to do
                // this, but it seems like we really should be doing this when
                // we receive this ACK. Maybe I'm misunderstanding the spec?
                sess.snd_wnd = p.tcp.wnd
                sess.snd_wl1 = p.tcp.seq
                sess.snd_wl2 = p.tcp.ack

                // TODO!
                /* if there is still data and other control stuff in this segment besides the synack {
                    keep processing it like we normally would when ESTABLISHED
                } else { */
                    return
                /* } */
            } else {
                // Just a SYN, but no ACK yet apparently. In this case, we
                // SYNACK and enter the SYN-RECEIVED state, basically like we
                // would expect the other side to have done. Apparently the
                // other side will know what to do with the extra SYN.
                node_log(n, "Got a SYN but no ACK. Moving from SYN-SENT to SYN-RECEIVED.")
                sess.state = TcpState.SynReceived
                send_packet(n, Packet{
                    dst_ip = p.src_ip,
                    protocol = PacketProtocol.TCP,
                    tcp = PacketTcp{
                        seq = sess.iss,
                        ack = sess.rcv_nxt,
                        control = TCP_SYN|TCP_ACK,
                        wnd = sess.rcv_wnd,
                    },
                    color = &COLOR_SYNACK,
                })

                sess.snd_wnd = p.tcp.wnd
                sess.snd_wl1 = p.tcp.seq
                sess.snd_wl2 = p.tcp.ack

                // TODO: Queue other controls and data for processing when ESTABLISHED.

                return
            }
        }

        if !is_syn && !is_rst {
            return
        }

        // I honestly have no idea if we can get here. Seems like a good place for a log.
        fmt.println("Flowed right out of SYN-SENT. Weird!")
    } else {
        // All other states have their control flow kind of collapsed together.
        // State-specific stuff will be handled as necessary.

        // Handle sequence numbers in all states.

        // Check if segment is acceptable (sequence number is somewhere in our
        // window, if not in order). This has four cases because of zeroes.
        acceptable: bool
        unacceptable_case: int
        if len(p.data) == 0 && sess.rcv_wnd == 0 {
            acceptable = p.tcp.seq == sess.rcv_nxt
            unacceptable_case = 1
        } else if len(p.data) == 0 && sess.rcv_wnd > 0 {
            acceptable = sess.rcv_nxt <= p.tcp.seq && p.tcp.seq < sess.rcv_nxt + u32(sess.rcv_wnd) // TODO(mod)
            unacceptable_case = 2
        } else if len(p.data) > 0 && sess.rcv_wnd == 0 {
            acceptable = false
            unacceptable_case = 3
        } else if len(p.data) > 0 && sess.rcv_wnd > 0 {
            segStart := p.tcp.seq
            segEnd := p.tcp.seq + u32(len(p.data))
            acceptable = (
                sess.rcv_nxt <= segStart && segStart < sess.rcv_nxt + u32(sess.rcv_wnd) || // TODO(mod)
                sess.rcv_nxt <= segEnd && segEnd < sess.rcv_nxt + u32(sess.rcv_wnd)) // TODO(mod)
            unacceptable_case = 4
        } else {
            fmt.println("ERROR! You messed up a case when checking for acceptable packets!")
            trap()
        }

        is_ack := p.tcp.control&TCP_ACK != 0
        is_rst := p.tcp.control&TCP_RST != 0
        if !acceptable {
            node_log(n, fmt.aprintf("Unacceptable segment (case %d).", unacceptable_case))
            node_log_tcp_packet(n, p)
            node_log_tcp_state(n, sess)

            if p.tcp.control&TCP_RST != 0 {
                return
            }

            // Send an ACK to try and let the other side know what we expect.
            batch_ack(sess)
            return
        }

        // Add packet to our receive buffer for ordered processing
        append(&sess.rcv_buffer, p)
    }
}

// Put stuff in this proc that needs to be handled in sequence order.
// If this function returns false, abort processing for this tick.
//
// TODO(ben): I think there's a _lot_ more that should be in this function...
// Can the handshake be handled in here? Parts of the handshake will have
// correct sequence numbers, but not all of it...
process_received_tcp_packet :: proc(n: ^Node, sess: ^TcpSession, p: Packet) -> bool {
    // TODO: Handle the following in some way:
    //
    //  In the following it is assumed that the segment is the idealized
    //  segment that begins at RCV.NXT and does not exceed the window. One
    //  could tailor actual segments to fit this assumption by trimming off
    //  any portions that lie outside the window (including SYN and FIN)
    //  and only processing further if the segment then begins at RCV.NXT.
    //  Segments with higher beginning sequence numbers SHOULD be held for
    //  later processing (SHLD-31).
    //

    // Only process this packet if it's the next one we expect.
    if p.tcp.seq != sess.rcv_nxt {
        batch_ack(sess) // Out-of-order packets mean we missed a packet, and need to tell the sender immediately!
        return false
    }

    // Not doing the security check they mention for a reset attack.

    // Handle a RST.
    if p.tcp.control&TCP_RST != 0 {
        // There is some nuance in the spec about how to handle the various
        // types of connection closes and resets. We don't care.
        node_log(n, "Got a RST while established; closing connection.")
        close_tcp_session(n, sess)
        return false
    }

    // Again, no security checks.

    // Handle a SYN.
    if p.tcp.control&TCP_SYN != 0 {
        if sess.state == TcpState.SynReceived {
            // We're still handshaking, already received a SYN, and now we
            // got another SYN. Just bail.
            node_log(n, "Got an extra SYN while handshaking. Giving up.")
            close_tcp_session(n, sess)
            return false
        } else {
            // Receiving a SYN while we are already synchronized could mean
            // a bunch of different things. Per RFC 5691, we send an ACK.
            //
            // TODO: Handle TIME-WAIT in a special way per the spec.
            node_log(n, fmt.aprintf("Received a SYN while already synchronized (in state %v). ACKing.", sess.state))
            send_packet(n, Packet{
                dst_ip = p.src_ip,
                protocol = PacketProtocol.TCP,
                tcp = PacketTcp{
                    // This is a bog-standard ACK of our current state.
                    seq = sess.snd_nxt,
                    ack = sess.rcv_nxt,
                    control = TCP_ACK,
                    wnd = sess.rcv_wnd,
                },
                color = &COLOR_ACK,
            })
            return true
        }
    }

    // Ensure that any packets we process at this point have an ACK.
    if p.tcp.control&TCP_ACK == 0 {
        return true
    }
    // From here on out, we know we have ACK data.

    // Ignoring the RFC 5691 blind data injection attack for now.

    if sess.state == TcpState.SynReceived {
        if sess.snd_una < p.tcp.ack && p.tcp.ack <= sess.snd_nxt { // TODO(mod)
            node_log(n, fmt.aprintf("Good ACK. Updating window and moving from %v to ESTABLISHED.", sess.state))
            sess.state = TcpState.Established
            sess.snd_wnd = p.tcp.wnd
            sess.snd_wl1 = p.tcp.seq
            sess.snd_wl2 = p.tcp.ack
        } else {
            // ACK outside the window while handshaking. Alas.
            node_log(n, "Got an ACK outside our window while handshaking:")
            node_log_tcp_state(n, sess)
            send_packet(n, Packet{
                dst_ip = p.src_ip,
                protocol = PacketProtocol.TCP,
                tcp = PacketTcp{
                    seq = p.tcp.ack,
                    control = TCP_RST,
                },
                color = &COLOR_RST,
            })
        }
    }

    // To avoid confusing control flow, we define good ESTABLISHED
    // packet processing as its own proc that we can call from all the
    // other various states. If this returns false, abort processing.
    process_established :: proc(n: ^Node, sess: ^TcpSession, p: Packet) -> bool {
        // Update send window based on ACK from other side.
        if sess.snd_una <= p.tcp.ack && p.tcp.ack <= sess.snd_nxt { // TODO(mod)
            window_moved_forward := sess.snd_wl1 < p.tcp.seq // TODO(mod)
            ack_moved_forward := sess.snd_wl1 == p.tcp.seq && sess.snd_wl2 <= p.tcp.ack // TODO(mod)
            if window_moved_forward || ack_moved_forward {
                sess.snd_wnd = p.tcp.wnd
                sess.snd_wl1 = p.tcp.seq
                sess.snd_wl2 = p.tcp.ack
            }
        }

        if p.tcp.ack <= sess.snd_una { // TODO(mod)
            // This ACK is a duplicate and can be ignored.
            node_log(n, "Duplicate ACK.")
            tcp_track_ack(n, sess, p.tcp.ack)
        } else if sess.snd_una < p.tcp.ack && p.tcp.ack <= sess.snd_nxt { // TODO(mod)
            node_log(n, "Advancing send window.")
            tcp_track_ack(n, sess, p.tcp.ack)
        } else {
            // ACK for something not yet sent. Ignore, and ACK back at them
            // to try and sort things out.
            node_log(n, "Received an ACK from the future. Ignoring and ACKing our current state:")
            node_log_tcp_state(n, sess)
            send_packet(n, Packet{
                dst_ip = p.src_ip,
                protocol = PacketProtocol.TCP,
                tcp = PacketTcp{
                    seq = sess.snd_nxt,
                    ack = sess.rcv_nxt,
                    control = TCP_ACK,
                    wnd = sess.rcv_wnd,
                },
                color = &COLOR_ACK,
            })
            return false
        }

        return true
    }

    #partial switch sess.state {
    case .Established:
        if !process_established(n, sess, p) do return true
    // TODO: All the other states...
    }

    // Process the segment's data
    sess.rcv_nxt += u32(len(p.data))
    if len(p.data) > 0 {
        node_log(n, fmt.aprintf("Received: \"%s\"", p.data))
        strings.write_string(&sess.received_data, p.data)

        batch_ack(sess)
    }

    // TODO: FIN

    // TODO: Timeouts (probably not here, but somewhere)

    return true
}

tcp_open :: proc(n: ^Node, dst_ip: u32) -> (^TcpSession, bool) {
    if sess_idx, already_connected := get_tcp_session(n, dst_ip); !already_connected {
        sess_idx, ok := new_tcp_session(n, dst_ip)
        assert(ok)

        sess := &n.tcp_sessions[sess_idx]

        iss := tcp_initial_sequence_num()
        syn := Packet{
            dst_ip = dst_ip,
            protocol = PacketProtocol.TCP,
            tcp = PacketTcp{
                seq = iss,
                control = TCP_SYN,
                wnd = sess.rcv_wnd, // TODO(ben): Is this used on SYNs?
            },
            color = &COLOR_SYN,
        }
        send_packet(n, syn)

        sess.iss = iss
        sess.snd_una = iss
        sess.snd_nxt = iss + 1

        sess.state = TcpState.SynSent

        return sess, true
    } else {
        return nil, false
    }
}

tcp_tick :: proc(n: ^Node) {
    for sess in &n.tcp_sessions {
        // Process received packets in order
        sort.quick_sort_proc(sess.rcv_buffer[:], proc(a, b: Packet) -> int {
            if a.tcp.seq < b.tcp.seq {
                return -1
            } else if a.tcp.seq > b.tcp.seq {
                return 1
            } else {
                return 0
            }
        })
        for len(sess.rcv_buffer) > 0 {
            p := sess.rcv_buffer[0]
            keep_going := process_received_tcp_packet(n, &sess, p)
            ordered_remove(&sess.rcv_buffer, 0)
            if !keep_going {
                break
            }
        }

        if sess.state == TcpState.Established {
            // HACK HACK HACK
            global_timeout := tick_count - sess.last_ack_timestamp > GLOBAL_TIMEOUT
            if global_timeout {
                new_cwnd: u32 = 1*SEG_SIZE // slow-start back up from 1
                if sess.cwnd_sent > new_cwnd {
                    node_log(n, "Hit global timeout. Reverting CWND to the minimum.")
                }
                sess.cwnd = new_cwnd
                sess.cwnd_sent = 0
                sess.cwnd_acked = 0
            }

            cwnd_available := sess.cwnd_sent < sess.cwnd
            if !congestion_control_on || cwnd_available {
                // Send the packet at the front of our send queue (or our retransmission queue...)
                should_send: bool
                to_send: Packet

                should_retransmit: bool
                for s, i in &sess.retransmit {
                    if tick_count - s.sent_at > sess.retransmit_timeout {
                        should_retransmit = true
                        break
                    }
                }
                if should_retransmit {
                    should_send = true
                    s := &sess.retransmit[0]
                    to_send = tcp_data_packet(&sess, s^)
                    node_log(n, fmt.aprintf("Retransmitting packet \"%s\" (SEG.SEQ=%d, sent at %d)", s.data, s.seq, s.sent_at))

                    // Retransmissions indicate congestion. Cut our
                    // congestion window to half the data in flight.
                    if s.retries == 0 {
                        sess.cwnd = max(sess.cwnd_sent/2, 2*SEG_SIZE)
                        sess.cwnd_sent = 0 // HACK??
                        node_log(n, fmt.aprintf("Cutting congestion window to %d", sess.cwnd))
                    }

                    s.sent_at = tick_count
                    s.retries += 1
                    sess.retransmit_timeout *= 2
                }

                if !should_send && len(sess.snd_buffer) > 0 {
                    should_send = true
                    to_send = sess.snd_buffer[0]
                    ordered_remove(&sess.snd_buffer, 0)
                }

                if should_send {
                    send_packet(n, to_send)

                    if !should_retransmit {
                        // Add the sent packet's data to the retransmission queue
                        append(&sess.retransmit, TcpSend{
                            data = to_send.data,
                            seq = to_send.tcp.seq,
                            sent_at = tick_count,
                        })
                    }

                    // Track sent bytes in cwnd
                    sess.cwnd_sent += u32(len(to_send.data))
                }
            }

            // Send any batched ACKs
            acks_are_ready := sess.first_ack_timestamp != 0
            ack_delay_expired := tick_count - sess.first_ack_timestamp >= ack_delay
            if acks_are_ready && ack_delay_expired {
                send_packet(n, Packet{
                    dst_ip = sess.ip,
                    protocol = PacketProtocol.TCP,
                    tcp = PacketTcp{
                        seq = sess.snd_nxt,
                        ack = sess.eventual_ack,
                        control = TCP_ACK,
                        wnd = sess.rcv_wnd,
                    },
                    color = &COLOR_ACK,
                })
                sess.first_ack_timestamp = 0
            }

            // Generate new outgoing packets at the end of the tick so we can see
            // them all queued up
            for tcp_send_window_remaining(&sess) >= SEG_SIZE && len(sess.snd_data) > 0 {
                // Grab a chunk of our output data and put it in our output queue
                send := TcpSend{
                    data = sess.snd_data[:min(SEG_SIZE, len(sess.snd_data))],
                    seq = sess.snd_nxt,
                }
                append(&sess.snd_buffer, tcp_data_packet(&sess, send))

                // Update send state
                sess.snd_data = sess.snd_data[min(SEG_SIZE, len(sess.snd_data)):]
                sess.snd_nxt += u32(len(send.data))
            }
        }

        for queue.len(sess.cwnd_history) >= history_size {
			queue.pop_front(&sess.cwnd_history)
		}
        for queue.len(sess.retransmit_history) >= history_size {
			queue.pop_front(&sess.retransmit_history)
		}
		queue.push_back(&sess.cwnd_history, u32(sess.cwnd))
		queue.push_back(&sess.retransmit_history, u32(len(sess.retransmit)))
    }
}

tcp_send_window_remaining :: proc(sess: ^TcpSession) -> u32 {
    send_window_end := sess.snd_una + u32(sess.snd_wnd)
    return send_window_end - sess.snd_nxt
}

tcp_data_packet :: proc(sess: ^TcpSession, s: TcpSend) -> Packet {
    return Packet{
        dst_ip = sess.ip,
        data = s.data,
        protocol = PacketProtocol.TCP,
        tcp = PacketTcp{
            seq = s.seq,
            ack = sess.rcv_nxt, // Always ACK because we can
            control = TCP_ACK,
            wnd = sess.rcv_wnd,
        },
        color = &text_color,
    }
}

tcp_initial_sequence_num :: proc() -> u32 {
    // no goofy hashes
    return u32(t / 4e-6)
}

send_packet :: proc(n: ^Node, p: Packet) {
    p := p
    p.src_ip = n.interfaces[0].ip
    p.anim = PacketAnimation.New
    p.src_node = n
    p.dst_node = n // not a mistake!
    p.src_bufid = queue.len(n.buffer)
    p.dst_bufid = queue.len(n.buffer)
    p.created_t = t
    queue.push_back(&n.buffer, p)

    node_log(n, "Sent packet:")
    node_log_tcp_packet(n, p)
}

get_tcp_session :: proc(n: ^Node, ip: u32) -> (int, bool) {
    for sess, idx in &n.tcp_sessions {
        if sess.ip == ip {
            return idx, true
        }
    }
    return 0, false
}

new_tcp_session :: proc(n: ^Node, ip: u32) -> (int, bool) {
    if existing_idx, ok := get_tcp_session(n, ip); ok {
		n.tcp_sessions[existing_idx] = TcpSession{ip = ip}
        return existing_idx, true
    }

	if len(n.tcp_sessions) >= 10 {
		return 0, false
	}

	append(&n.tcp_sessions, TcpSession{
        ip = ip,
        rcv_wnd = 200, // TODO(ben): This is arbitrary for now!
        cwnd = 2*SEG_SIZE, // Start small so we can see slow start.
        retransmit_timeout = new_retransmit_timeout(),
        received_data = strings.builder_make(),
    })
	return len(n.tcp_sessions) - 1, true
}

close_tcp_session :: proc(n: ^Node, sess: ^TcpSession) {
    for node_sess, i in &n.tcp_sessions {
        if sess == &node_sess {
	        unordered_remove(&n.tcp_sessions, i)
        }
    }
}

tcp_send :: proc(sess: ^TcpSession, data: string) {
   sess.snd_data = data
}

tcp_track_ack :: proc(n: ^Node, sess: ^TcpSession, ack: u32) {
    sess.last_ack_timestamp = tick_count

    ack_diff := ack - sess.snd_una
    sess.cwnd_sent -= min(sess.cwnd_sent, ack_diff) // the amount of data remaining in the network
    sess.cwnd_acked += ack_diff
    
    sess.snd_una = ack

    // Goofy-looking double for, but it makes for nicer logs and less index confusion on my part.
    // I don't care that it's quadratic. It doesn't matter.
    num_packets_acked := 0
    startover:
    for {
        for s, i in sess.retransmit {
            s := sess.retransmit[i]
            if s.seq + u32(len(s.data)) <= ack {
                node_log(n, fmt.aprintf("Clearing retransmission of \"%s\"", s.data))
                ordered_remove(&sess.retransmit, i)
                num_packets_acked += 1
                continue startover
            }
        }
        break
    }
    sess.retransmit_timeout = new_retransmit_timeout()

    should_increase_cwnd := false
    if sess.cwnd < SSTHRESH {
        // Slow start; increase on every ACK
        should_increase_cwnd = true
    } else {
        // Normal congestiona avoidance; increase congestion window whenever we
        // successfully ACK a window's worth of content.
        if sess.cwnd_acked >= sess.cwnd {
            should_increase_cwnd = true
        }
    }

    if should_increase_cwnd {
        sess.cwnd += SEG_SIZE
        // sess.cwnd_sent = 0
        sess.cwnd_acked = 0
        node_log(n, fmt.aprintf("Increasing congestion window to %d", sess.cwnd))
    }
}

batch_ack :: proc(sess: ^TcpSession) {
    if sess.first_ack_timestamp == 0 {
        sess.first_ack_timestamp = tick_count
        sess.eventual_ack = 0
    }
    sess.eventual_ack = max(sess.eventual_ack, sess.rcv_nxt)
}

ack_now :: proc(n: ^Node, sess: ^TcpSession) {
    send_packet(n, Packet{
        dst_ip = sess.ip,
        protocol = PacketProtocol.TCP,
        tcp = PacketTcp{
            seq = sess.snd_nxt,
            ack = sess.eventual_ack,
            control = TCP_ACK,
            wnd = sess.rcv_wnd,
        },
        color = &COLOR_ACK,
    })
}

new_retransmit_timeout :: proc() -> int {
    return RETRANSMIT_TIMEOUT + int(rand.int31() % RETRANSMIT_JITTER)
}

node_log_packet :: proc(n: ^Node, p: Packet) {
    node_log(n, fmt.aprintf("  Protocol: %v", p.protocol))
    node_log_tcp_packet(n, p)
}

node_log_tcp_packet :: proc(n: ^Node, p: Packet) {
    node_log(n, fmt.aprintf("  SEG: SEQ=%v, ACK=%v, LEN=%v, WND=%v", p.tcp.seq, p.tcp.ack, len(p.data), p.tcp.wnd))
    node_log(n, fmt.aprintf("  Control: %v", control_flag_str(p.tcp.control)))
    if len(p.data) > 0 {
        node_log(n, fmt.aprintf("  Data: \"%s\"", p.data))
    }
}

node_log_tcp_state :: proc(n: ^Node, sess: ^TcpSession) {
    node_log(n, fmt.aprintf("  SND: NXT=%v, WND=%v, UNA=%v", sess.snd_nxt, sess.snd_wnd, sess.snd_una))
    node_log(n, fmt.aprintf("  RCV: NXT=%v, WND=%v", sess.rcv_nxt, sess.rcv_wnd))
    node_log(n, fmt.aprintf("  ISS: %v, IRS: %v", sess.iss, sess.irs))
    node_log(n, fmt.aprintf("  CWND: %v, SENT=%v, CWND=%v", sess.cwnd, sess.cwnd_sent, sess.cwnd_acked))
}
