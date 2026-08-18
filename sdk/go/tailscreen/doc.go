// Package tailscreen implements the Tailscreen wire protocol: the codecs for
// the UDP control plane, RTP video and audio, the layered loss recovery, and
// the framed TCP channel that carries annotations, remote control and
// metadata.
//
// It is a complete implementation of the codec layer defined by the
// specification in docs/spec.md, written from that document and sharing no
// code with the Swift implementation the Tailscreen apps ship. Both are run
// against the same conformance vectors, which is what lets this package be
// offered as something to build on rather than as a demonstration.
//
// # Scope
//
// This package encodes and decodes. It owns no socket, no timer and no
// policy: the specification's timeouts, admission decisions, congestion
// control and grant lifecycle are yours to implement, and the constants they
// need are exported here (KeepaliveInterval, IdleTimeout, and the rest).
// That boundary is deliberate — a client that wants its own event loop, its
// own concurrency model or its own transport should not have to fight one
// built into a codec library.
//
// It also does not speak Tailscale. The protocol assumes it is running inside
// a Tailscale tunnel and defines no authentication, encryption or integrity
// protection of its own (TS-GEN-011); connect the sockets yourself, through
// tsnet or a host tailnet, and do not put this on an open network.
//
// # A minimal viewer
//
// The viewer half of a session is a handshake, a keepalive and a demultiplex:
//
//	conn, err := net.Dial("udp", net.JoinHostPort(peer, strconv.Itoa(tailscreen.Port)))
//	if err != nil {
//		return err
//	}
//	caps := tailscreen.CapNACK | tailscreen.CapReceiverReport | tailscreen.CapFEC
//	conn.Write(tailscreen.EncodeHello(caps))
//
//	buf := make([]byte, 2048)
//	for {
//		n, err := conn.Read(buf)
//		if err != nil {
//			return err
//		}
//		datagram := buf[:n]
//
//		if tailscreen.Classify(datagram) == tailscreen.ClassRTP {
//			header, offset, ok := tailscreen.DecodeRTPHeader(datagram)
//			if !ok {
//				continue // TS-GEN-022, TS-VID-002: discard, never error out
//			}
//			handleMedia(header, datagram[offset:])
//			continue
//		}
//
//		kind, ok := tailscreen.DecodeControl(datagram)
//		if !ok {
//			continue // TS-CTL-002: an unknown byte is not an error
//		}
//		switch kind {
//		case tailscreen.HelloAck:
//			ssrc, serverCaps, _ := tailscreen.DecodeHelloAckTolerant(datagram)
//			negotiated := tailscreen.Negotiate(caps, serverCaps)
//			admitted(ssrc, negotiated)
//		case tailscreen.HelloPending:
//			awaitingApproval()
//		case tailscreen.HelloDenied:
//			declined()
//		case tailscreen.ServerBye:
//			return nil
//		}
//	}
//
// Note what the loop does with input it does not understand: it discards it
// and carries on. That is the protocol's entire compatibility story
// (TS-EXT-001), and an implementation that treats an unknown byte as an
// error will break against the next peer that ships a feature it lacks.
//
// # Errors
//
// The byte-level codecs report failure as an ok boolean rather than an
// error. There is exactly one failure mode — the datagram was malformed —
// and the specification's answer to it is always the same: discard it
// silently. A caller has nothing to inspect and nothing to report, so an
// error value would carry no information.
//
// The JSON payload decoders do return errors, because they are the layer
// where a caller may reasonably want to log what a peer sent.
//
// # Requirement identifiers
//
// Doc comments cite the requirements they implement (TS-CTL-002, TS-FEC-010,
// …). They index docs/spec.md, and the conformance vectors cite the same
// ones, so a behaviour, its rule and its test are findable from each other.
package tailscreen
