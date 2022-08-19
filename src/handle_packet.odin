package main

import "core:container/queue"

COLOR_RST :: Vec3{220, 80, 80}
COLOR_SYNACK :: Vec3{80, 80, 220}

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
    sess, ok := get_tcp_session(n, p.src_ip)
    if !ok && !n.listening {
        // CLOSED state (3.10.7.1)

        // RSTs are ignored while closed; we're already closed.
        if p.tcp.control_flags&TCP_RST != 0 {
            return
        }

        // Any other packet causes a RST to be sent in return. The details of
        // the sequence and ack numbers are weird and I just trust the spec.
        if p.tcp.control_flags&TCP_ACK == 0 {
            send_packet(n, Packet{
                dst_ip = p.src_ip,
                protocol = PacketProtocol.TCP,
                tcp = PacketTcp{
                    sequence_number = 0,
                    ack_number = p.tcp.sequence_number + u32(len(p.data)),
                    control_flags = TCP_RST|TCP_ACK,
                },
                color = COLOR_RST,
            })
        } else {
            send_packet(n, Packet{
                dst_ip = p.src_ip,
                protocol = PacketProtocol.TCP,
                tcp = PacketTcp{
                    sequence_number = p.tcp.ack_number,
                    control_flags = TCP_RST,
                },
                color = COLOR_RST,
            })
        }
        return
    } else if !ok && n.listening {
        // LISTEN state (3.10.7.2)

        // RSTs are ignored; they could not possibly be relevant since we haven't sent anything.
        if p.tcp.control_flags&TCP_RST != 0 {
            return
        }

        // ACKs are no good if we're in LISTEN; we haven't sent anything to be ACKed!
        // Send a RST.
        if p.tcp.control_flags&TCP_ACK != 0 {
            send_packet(n, Packet{
                dst_ip = p.src_ip,
                protocol = PacketProtocol.TCP,
                tcp = PacketTcp{
                    sequence_number = p.tcp.ack_number,
                    control_flags = TCP_RST,
                },
                color = COLOR_RST,
            })
            return
        }

        // SYNs mean we're starting up a new connection.
        if p.tcp.control_flags&TCP_SYN != 0 {
            sess, ok := new_tcp_session(n, p.src_ip)
            if !ok {
                // Out of resources! Die.
                return
            }

            // No security concerns here.

            sess.initial_receive_seq_num = p.tcp.sequence_number
            sess.receive_next = p.tcp.sequence_number + 1

            // TODO: Queue any data in this packet to be processed later.
            // The sender can include data in the initial SYN packet.

            sess.initial_send_seq_num = tcp_initial_sequence_num()
            send_packet(n, Packet{
                dst_ip = p.src_ip,
                protocol = PacketProtocol.TCP,
                tcp = PacketTcp{
                    sequence_number = sess.initial_send_seq_num,
                    ack_number = sess.receive_next,
                    control_flags = TCP_SYN|TCP_ACK,
                },
                color = COLOR_SYNACK,
            })

            sess.send_unacknowledged = sess.initial_send_seq_num
            sess.send_next = sess.initial_send_seq_num + 1

            sess.state = TcpState.SynReceived

            // Maybe in the future handle other control codes here?

            return
        }

        // This should never be reached. Well-behaved TCP packets would have
        // been caught by one of the above cases. Of course, this is a sim, so
        // it will probably happen a lot :)
        return
    }

    // Now, on to the actual session states...
    assert(sess != nil)

    if sess.state == TcpState.SynSent {
        // SYN-SENT (3.10.7.3)

        is_syn := p.tcp.control_flags&TCP_SYN != 0
        is_ack := p.tcp.control_flags&TCP_ACK != 0
        is_rst := p.tcp.control_flags&TCP_RST != 0

        // Handle an ACK, specifically a bad one. Since we sent the initial
        // SYN, we're expecting an ACK back, but also expecting a SYN. All the
        // good behavior is handled later on.
        if is_ack {
            // All ACKs must be for data in our unacknowledged window; that is,
            // between the last un-ACKed seq number and the next one we're gonna
            // send. Anything outside this triggers a RST.
            bad_ack := p.tcp.ack_number <= sess.initial_send_seq_num || p.tcp.ack_number > sess.send_next // TODO(mod)
            if bad_ack {
                if is_rst {
                    return // Don't RST a RST.
                }

                send_packet(n, Packet{
                    dst_ip = p.src_ip,
                    protocol = PacketProtocol.TCP,
                    tcp = PacketTcp{
                        sequence_number = p.tcp.ack_number,
                        control_flags = TCP_RST,
                    },
                    color = COLOR_RST,
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
                close_tcp_session(sess)
            }
            return
        }

        // No security checks.

        // At this point, we either have a good ACK or no ACK at all.

        // Handle a SYN, and maybe a SYNACK
        if is_syn {
            sess.initial_receive_seq_num = p.tcp.sequence_number
            sess.receive_next = p.tcp.sequence_number + 1
            if is_ack {
                sess.send_unacknowledged = p.tcp.ack_number
                // TODO: Advance past any segments that need to be retried.
            }

            if sess.send_unacknowledged > send.initial_send_seq_num {
                // The SYN we sent has been ACKed, plus we got a SYN in return.
                // We can ACK back, and at this point we're established.
                sess.state = TcpState.Established
                send_packet(n, Packet{
                    dst_ip = p.src_ip,
                    protocol = PacketProtocol.TCP,
                    tcp = PacketTcp{
                        sequence_number = sess.send_next,
                        ack_number = sess.receive_next,
                        control_flags = TCP_ACK,
                    },
                    color = COLOR_ACK,
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
                sess.state = TcpState.SynReceived
                send_packet(n, Packet{
                    dst_ip = p.src_ip,
                    protocol = PacketProtocol.TCP,
                    tcp = PacketTcp{
                        sequence_number = sess.initial_send_seq_num,
                        ack_number = sess.receive_next,
                        control_flags = TCP_SYN|TCP_ACK,
                    },
                    color = COLOR_SYNACK,
                })

                sess.send_window = p.tcp.window
                sess.last_window_update_seq_num = p.tcp.sequence_number
                sess.last_window_update_ack_num = p.tcp.ack_number

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
}

get_tcp_session :: proc(n: ^Node, ip: u32) -> (^TcpSession, bool) {
    for sess in &n.tcp_sessions {
        if sess.ip == ip {
            return &sess, true
        }
    }
    return nil, false
}

new_tcp_session :: proc(n: ^Node, ip: u32) -> (^TcpSession, bool) {
    if existing, ok := get_tcp_session(n, ip); ok {
        existing^ = TcpSession{ip = ip}
        return existing, true
    }
    for sess in &n.tcp_sessions {
        if sess.ip == 0 {
            (&sess)^ = TcpSession{ip = ip}
            return &sess, true
        }
    }
    return nil, false
}

close_tcp_session :: proc(sess: ^TcpSession) {
    sess^ = TcpSession{}
}
