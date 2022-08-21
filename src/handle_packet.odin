package main

import "core:container/queue"
import "core:fmt"

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
                close_tcp_session(n, sess_idx)
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
                sess.snd_una = p.tcp.ack
                // TODO: Advance past any segments that need to be retried.
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
                    },
                    color = &COLOR_ACK,
                })

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
        if !acceptable && !is_ack && !is_rst {
            node_log(n, fmt.aprintf("Unacceptable segment (case %d).", unacceptable_case))
            node_log_tcp_packet(n, p)
            node_log_tcp_state(n, sess)
            running = false

            if p.tcp.control&TCP_RST != 0 {
                return
            }

            // Send an ACK to try and let the other side know what we expect.
            send_packet(n, Packet{
                dst_ip = p.src_ip,
                protocol = PacketProtocol.TCP,
                tcp = PacketTcp{
                    // This is a bog-standard ACK of our current state.
                    seq = sess.snd_nxt,
                    ack = sess.rcv_nxt,
                    control = TCP_ACK,
                },
                color = &COLOR_ACK,
            })
            return
        }

        // TODO: Actually queue up packets for good processing and handle sequence numbers!

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

        // Not doing the security check they mention for a reset attack.

        // Handle a RST.
        if p.tcp.control&TCP_RST != 0 {
            // There is some nuance in the spec about how to handle the various
            // types of connection closes and resets. We don't care.
            node_log(n, "Got a RST while established; closing connection.")
            close_tcp_session(n, sess_idx)
            return
        }

        // Again, no security checks.

        // Handle a SYN.
        if p.tcp.control&TCP_SYN != 0 {
            if sess.state == TcpState.SynReceived {
                // We're still handshaking, already received a SYN, and now we
                // got another SYN. Just bail.
                node_log(n, "Got an extra SYN while handshaking. Giving up.")
                close_tcp_session(n, sess_idx)
                return
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
                    },
                    color = &COLOR_ACK,
                })
                return
            }
        }

        // Ensure that any packets we process at this point have an ACK.
        if p.tcp.control&TCP_ACK == 0 {
            return
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
                node_log(n, "Duplicate ACK. No worries.")
            } else if sess.snd_una < p.tcp.ack && p.tcp.ack <= sess.snd_nxt { // TODO(mod)
                node_log(n, "Advancing send window.")
                sess.snd_una = p.tcp.ack
                // TODO: Clear acknowledged segments from the retransmission queue.
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
                    },
                    color = &COLOR_ACK,
                })
                return false
            }

            return true
        }

        #partial switch sess.state {
        case .Established:
            if !process_established(n, sess, p) do return
        // TODO: All the other states...
        }

        // Process the segment's data
        node_log(n, fmt.aprintf("Received: %s", p.data))
        sess.rcv_nxt += u32(len(p.data))
        if len(p.data) > 0 {
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
        }

        // TODO: FIN

        // TODO: Timeouts (probably not here, but somewhere)
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

	append(&n.tcp_sessions, TcpSession{ip = ip})
	return len(n.tcp_sessions) - 1, true
}

close_tcp_session :: proc(n: ^Node, sess_idx: int) {
	unordered_remove(&n.tcp_sessions, sess_idx)
}

node_log_tcp_packet :: proc(n: ^Node, p: Packet) {
    node_log(n, fmt.aprintf("  SEG: SEQ=%v, ACK=%v, LEN=%v, WND=%v", p.tcp.seq, p.tcp.ack, len(p.data), p.tcp.wnd))
    node_log(n, fmt.aprintf("  Control: %v", control_flag_str(p.tcp.control)))
    if len(p.data) > 0 {
        node_log(n, fmt.aprintf("  Data: %s", p.data))
    }
}

node_log_tcp_state :: proc(n: ^Node, sess: ^TcpSession) {
    node_log(n, fmt.aprintf("  State: %v", sess.state))
    node_log(n, fmt.aprintf("  SND.UNA: %v", sess.snd_una))
    node_log(n, fmt.aprintf("  SND.NXT: %v", sess.snd_nxt))
    node_log(n, fmt.aprintf("  SND.WND: %v", sess.snd_wnd))
    node_log(n, fmt.aprintf("  ISS: %v", sess.iss))
    node_log(n, fmt.aprintf("  RCV.NXT: %v", sess.rcv_nxt))
    node_log(n, fmt.aprintf("  RCV.WND: %v", sess.rcv_wnd))
    node_log(n, fmt.aprintf("  IRS: %v", sess.irs))
}
