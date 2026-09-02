//go:build js && wasm

package main

import (
	"encoding/binary"
	"fmt"
	"syscall/js"
	"time"

	"github.com/middle-management/tailscreen/sdk/go/tailscreen"
)

// The viewer session, Phase 3 of plans/browser-viewer.md: the receive
// pipeline the native apps run in ViewerSession, here over sdk/go, driven by
// the page's clock exactly the way the SDK asks — no goroutine, no timer,
// every time-driven decision takes nowNs from the caller.
//
//	tailscreenNewSession({caps?}) → {
//	  ingest(datagram, nowNs) → { video: [AU], audio: [Frame], control: [name], send: [Uint8Array] }
//	  tick(nowNs)             → [Uint8Array]   datagrams to send now (HELLO/KEEPALIVE/RR/PLI)
//	  requestKeyframe()                         a decode failure: PLI on the next tick, rate-limited
//	  codecUnsupported()                        CODEC_NO once — the sharer falls back to H.264
//	  state()                 → { state, ssrc, serverCaps, stats… }
//	}
//
// An AU is { avcc, annexb, keyframe, timestamp, codec, codecString, sps, pps, vps, lostBefore }:
// AVCC is what the depacketizer hands a decoder (4-byte length prefixes,
// WebCodecs' "avc" format with an avcC description built from sps/pps), Annex B
// is the start-code form for decoders configured without a description.
type session struct {
	caps       tailscreen.Caps
	state      string
	ssrc       uint32
	serverCaps tailscreen.Caps

	h264 *tailscreen.Depacketizer
	hevc *tailscreen.Depacketizer
	rr   *tailscreen.RRAccounting

	lastHelloNs        uint64
	lastKeepaliveNs    uint64
	lastReportNs       uint64
	sentFirstReport    bool
	lastPingTs         uint64
	lastPingReceivedNs uint64

	seenKeyframe      bool
	keyframeRequested bool // a PLI is owed (decode failure or first-keyframe wait)
	lastKeyframeReqNs uint64
	codecNoOwed       bool
	codecNoSent       bool

	// Stats the HUD shows.
	rtpVideo, rtpAudio, rtpBytes, videoAUs, keyframes, tornAUs, pliSent, reports int
}

const (
	// The native viewer's cadences (TransportTuning / ViewerSession).
	keepaliveIntervalNs       = uint64(tailscreen.KeepaliveInterval)
	receiverReportIntervalNs  = uint64(time.Second)
	keyframeRequestIntervalNs = uint64(time.Second)
	// In-order transport: a gap can only be a sender-side shed (TS-STM-006),
	// so hold it briefly and move on rather than the 300 ms NACK-mode hold.
	reorderDepth  = 256
	reorderHoldNs = uint64(50 * time.Millisecond)
)

func newSession(caps tailscreen.Caps) *session {
	return &session{
		caps:  caps,
		state: "connecting",
		h264:  tailscreen.NewH264Depacketizer(reorderDepth, reorderHoldNs),
		hevc:  tailscreen.NewH265Depacketizer(reorderDepth, reorderHoldNs),
		rr:    tailscreen.NewRRAccounting(),
	}
}

func newSessionJS(this js.Value, args []js.Value) any {
	// receiverReport only, per TS-STM-005: a stream viewer never advertises
	// NACK or FEC. The page may pass {caps} to override for experiments.
	caps := tailscreen.CapReceiverReport
	if len(args) > 0 && args[0].Type() == js.TypeObject {
		if v := args[0].Get("caps"); v.Type() == js.TypeNumber {
			caps = tailscreen.Caps(v.Int())
		}
	}
	s := newSession(caps)
	return map[string]any{
		"ingest": js.FuncOf(func(this js.Value, args []js.Value) any {
			if len(args) < 2 {
				return js.Null()
			}
			return s.ingest(toBytes(args[0]), uint64(args[1].Float()))
		}),
		"tick": js.FuncOf(func(this js.Value, args []js.Value) any {
			if len(args) < 1 {
				return js.Null()
			}
			out := s.tick(uint64(args[0].Float()))
			arr := js.Global().Get("Array").New(len(out))
			for i, d := range out {
				arr.SetIndex(i, toU8(d))
			}
			return arr
		}),
		"requestKeyframe": js.FuncOf(func(this js.Value, args []js.Value) any {
			s.keyframeRequested = true
			return nil
		}),
		"codecUnsupported": js.FuncOf(func(this js.Value, args []js.Value) any {
			s.codecNoOwed = true
			return nil
		}),
		"state": js.FuncOf(func(this js.Value, args []js.Value) any {
			return s.stateJS()
		}),
	}
}

func (s *session) stateJS() map[string]any {
	return map[string]any{
		"state":      s.state,
		"ssrc":       int64(s.ssrc),
		"serverCaps": int(s.serverCaps),
		"caps":       int(s.caps),
		"stats": map[string]any{
			"rtpVideo": s.rtpVideo, "rtpAudio": s.rtpAudio, "rtpBytes": s.rtpBytes,
			"videoAUs": s.videoAUs, "keyframes": s.keyframes, "tornAUs": s.h264.TornAUCount() + s.hevc.TornAUCount(),
			"skippedGaps": s.h264.SkippedGapCount() + s.hevc.SkippedGapCount(),
			"pliSent":     s.pliSent, "reports": s.reports,
		},
	}
}

func (s *session) ingest(b []byte, nowNs uint64) map[string]any {
	video := js.Global().Get("Array").New()
	audio := js.Global().Get("Array").New()
	control := js.Global().Get("Array").New()
	out := map[string]any{"video": video, "audio": audio, "control": control}

	switch tailscreen.Classify(b) {
	case tailscreen.ClassEmpty:
		return out
	case tailscreen.ClassRTP:
		h, off, ok := tailscreen.DecodeRTPHeader(b)
		if !ok {
			return out
		}
		s.rtpBytes += len(b)
		switch h.PayloadType {
		case tailscreen.PTH264, tailscreen.PTHEVC:
			s.rtpVideo++
			s.rr.Observe(h.Sequence)
			d := s.h264
			if h.PayloadType == tailscreen.PTHEVC {
				d = s.hevc
			}
			if au := d.Ingest(b, nowNs); au != nil {
				video.Call("push", s.auJS(au))
			}
			for _, au := range d.DrainReady() {
				video.Call("push", s.auJS(&au))
			}
		case tailscreen.PTVoice, tailscreen.PTSystemAudio:
			s.rtpAudio++
			audio.Call("push", map[string]any{
				"payload": toU8(b[off:]), "pt": int(h.PayloadType), "ssrc": int64(h.SSRC),
				"seq": int(h.Sequence), "timestamp": int64(h.Timestamp),
			})
		}
		return out
	}

	kind, ok := tailscreen.DecodeControl(b)
	if !ok {
		return out
	}
	name, _ := tailscreen.ControlName(kind)
	control.Call("push", name)
	switch kind {
	case tailscreen.HelloAck:
		ssrc, caps, ok := tailscreen.DecodeHelloAckTolerant(b)
		if ok {
			s.ssrc = ssrc
			s.serverCaps = caps
		}
		if s.state != "acked" {
			s.state = "acked"
			// First keyframe: ask once now rather than waiting for the
			// sharer's next periodic IDR (the native viewer does the same).
			if !s.seenKeyframe {
				s.keyframeRequested = true
			}
		}
	case tailscreen.HelloPending:
		if s.state != "acked" {
			s.state = "pending"
		}
	case tailscreen.HelloDenied:
		s.state = "denied"
	case tailscreen.ServerBye:
		if s.state != "denied" {
			s.state = "ended"
		}
	case tailscreen.Ping:
		if ts, ok := tailscreen.DecodePing(b); ok {
			s.lastPingTs = ts
			s.lastPingReceivedNs = nowNs
		}
	}
	return out
}

func (s *session) auJS(au *tailscreen.VideoAccessUnit) map[string]any {
	s.videoAUs++
	if au.ContainsIDR {
		s.keyframes++
		s.seenKeyframe = true
	}
	if au.LostBeforeThisAU && s.seenKeyframe {
		// TS-VID-044: the depacketizer says a gap was abandoned before this
		// AU; only a keyframe makes the decoder whole again.
		s.keyframeRequested = true
	}
	hevc := au.Codec == "hevc"
	sps, pps, vps := parameterSets(au.AVCC, hevc)
	codecString := ""
	if sps != nil {
		if hevc {
			codecString = hevcCodecString(sps)
		} else {
			codecString = h264CodecString(sps)
		}
	}
	m := map[string]any{
		"avcc":        toU8(au.AVCC),
		"annexb":      toU8(annexB(au.AVCC)),
		"keyframe":    au.ContainsIDR,
		"timestamp":   int64(au.Timestamp),
		"codec":       au.Codec,
		"codecString": codecString,
		"lostBefore":  au.LostBeforeThisAU,
		"sps":         js.Null(),
		"pps":         js.Null(),
		"vps":         js.Null(),
	}
	if sps != nil {
		m["sps"] = toU8(sps)
	}
	if pps != nil {
		m["pps"] = toU8(pps)
	}
	if vps != nil {
		m["vps"] = toU8(vps)
	}
	return m
}

func (s *session) tick(nowNs uint64) [][]byte {
	var out [][]byte
	switch s.state {
	case "connecting", "pending":
		// HELLO until answered with an ACK; the sharer re-echoes PENDING to
		// each one while we wait, which is also how it keeps the parked row
		// alive.
		if s.lastHelloNs == 0 || nowNs-s.lastHelloNs >= keepaliveIntervalNs {
			s.lastHelloNs = nowNs
			if s.caps == 0 {
				out = append(out, tailscreen.EncodeControl(tailscreen.Hello))
			} else {
				out = append(out, tailscreen.EncodeHello(s.caps))
			}
		}
		return out
	case "acked":
	default:
		return nil
	}

	if s.lastKeepaliveNs == 0 || nowNs-s.lastKeepaliveNs >= keepaliveIntervalNs {
		s.lastKeepaliveNs = nowNs
		out = append(out, tailscreen.EncodeControl(tailscreen.Keepalive))
	}
	if s.caps.Has(tailscreen.CapReceiverReport) && s.rr.HasBaseline() &&
		(!s.sentFirstReport || nowNs-s.lastReportNs >= receiverReportIntervalNs) {
		if frac, ext, ok := s.rr.MakeReport(); ok {
			delayMs := uint64(0)
			if s.lastPingTs != 0 {
				delayMs = (nowNs - s.lastPingReceivedNs) / 1e6
				if delayMs > 0xFFFF {
					delayMs = 0xFFFF
				}
			}
			out = append(out, tailscreen.EncodeReport(tailscreen.Report{
				FracLostQ8: frac, ExtHighestSeq: ext, LastPingTs: s.lastPingTs,
				DelaySincePingMs: uint16(delayMs),
			}, false))
			s.lastReportNs = nowNs
			s.sentFirstReport = true
			s.reports++
		}
	}
	if s.keyframeRequested && (s.lastKeyframeReqNs == 0 || nowNs-s.lastKeyframeReqNs >= keyframeRequestIntervalNs) {
		s.keyframeRequested = false
		s.lastKeyframeReqNs = nowNs
		s.pliSent++
		out = append(out, tailscreen.EncodeControl(tailscreen.PLI))
	}
	if s.codecNoOwed && !s.codecNoSent {
		s.codecNoSent = true
		out = append(out, tailscreen.EncodeControl(tailscreen.CodecUnsupported))
	}
	return out
}

// --- bitstream helpers ------------------------------------------------------------

// forEachNAL walks an AVCC access unit (4-byte big-endian length prefixes).
func forEachNAL(avcc []byte, f func(nal []byte)) {
	for len(avcc) >= 4 {
		n := int(binary.BigEndian.Uint32(avcc))
		avcc = avcc[4:]
		if n <= 0 || n > len(avcc) {
			return
		}
		f(avcc[:n])
		avcc = avcc[n:]
	}
}

func annexB(avcc []byte) []byte {
	out := make([]byte, 0, len(avcc)+16)
	forEachNAL(avcc, func(nal []byte) {
		out = append(out, 0, 0, 0, 1)
		out = append(out, nal...)
	})
	return out
}

// parameterSets pulls the in-band SPS/PPS (and VPS for HEVC) out of an access
// unit; nil for each not present. Every keyframe carries them (§7.3).
func parameterSets(avcc []byte, hevc bool) (sps, pps, vps []byte) {
	forEachNAL(avcc, func(nal []byte) {
		if len(nal) < 2 {
			return
		}
		if hevc {
			switch (nal[0] >> 1) & 0x3F {
			case 32:
				vps = nal
			case 33:
				sps = nal
			case 34:
				pps = nal
			}
			return
		}
		switch nal[0] & 0x1F {
		case 7:
			sps = nal
		case 8:
			pps = nal
		}
	})
	return
}

// h264CodecString is the RFC 6381 avc1.PPCCLL form straight off the SPS.
func h264CodecString(sps []byte) string {
	if len(sps) < 4 {
		return ""
	}
	return fmt.Sprintf("avc1.%02X%02X%02X", sps[1], sps[2], sps[3])
}

// hevcCodecString is the ISO 14496-15 Annex E form (hev1 — parameter sets
// in-band, which is how they arrive): profile space+idc, the compatibility
// flags bit-reversed, tier+level, then the constraint bytes with trailing
// zeros dropped.
func hevcCodecString(sps []byte) string {
	// 2-byte NAL header, 1 byte of sps_video_parameter_set_id /
	// max_sub_layers_minus1 / temporal_id_nesting, then profile_tier_level.
	const ptl = 3
	if len(sps) < ptl+12 {
		return ""
	}
	p := sps[ptl:]
	space := p[0] >> 6
	tier := (p[0] >> 5) & 1
	profile := p[0] & 0x1F
	compat := binary.BigEndian.Uint32(p[1:5])
	var reversed uint32
	for i := 0; i < 32; i++ {
		if compat&(1<<uint(31-i)) != 0 {
			reversed |= 1 << uint(i)
		}
	}
	constraint := p[5:11]
	level := p[11]
	spaceLetter := ""
	if space > 0 {
		spaceLetter = string(rune('A' + space - 1))
	}
	tierLetter := "L"
	if tier == 1 {
		tierLetter = "H"
	}
	out := fmt.Sprintf("hev1.%s%d.%X.%s%d", spaceLetter, profile, reversed, tierLetter, level)
	end := len(constraint)
	for end > 0 && constraint[end-1] == 0 {
		end--
	}
	for _, c := range constraint[:end] {
		out += fmt.Sprintf(".%X", c)
	}
	return out
}
