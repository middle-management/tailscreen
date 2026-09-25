// Package tailscreen implements the Tailscreen wire protocol: the codecs for
// the UDP control plane, RTP video and audio, the layered loss recovery, and
// the framed TCP channel that carries annotations, remote control and
// metadata.
//
// It implements the codec layer defined in docs/spec.md, written from that
// document and sharing no code with the Swift implementation the Tailscreen
// apps ship; both run against the same conformance vectors.
//
// # Scope
//
// This package encodes and decodes only. It owns no socket, timer or policy:
// timeouts, admission, congestion control and grant lifecycle are yours to
// implement (constants like KeepaliveInterval, IdleTimeout are exported for
// that). This lets a client bring its own event loop, concurrency model or
// transport.
//
// It also does not speak Tailscale. The protocol defines no authentication,
// encryption or integrity of its own (TS-GEN-011) and assumes it runs inside
// a Tailscale tunnel — connect the sockets yourself and never expose it to an
// open network.
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
// The loop discards input it doesn't understand and carries on — the
// protocol's entire compatibility story (TS-EXT-001); treating an unknown
// byte as an error breaks against any peer with a feature you lack.
//
// # Errors
//
// Byte-level codecs report failure as an ok boolean, not an error: the only
// failure mode is a malformed datagram, and the spec's answer is always
// silent discard, so there's nothing to report.
//
// JSON payload decoders do return errors, since callers may want to log what
// a peer sent.
//
// # Requirement identifiers
//
// Doc comments cite the requirements they implement (TS-CTL-002, TS-FEC-010,
// …). They index docs/spec.md, and the conformance vectors cite the same
// ones, so a behaviour, its rule and its test are findable from each other.
package tailscreen
