// Package conformance dispatches the language-neutral vectors in ../vectors
// against the public Go implementation in ../../sdk/go/tailscreen.
//
// Each vector names an `op`, an `in` object and an expected `out` object.
// The dispatcher below is the whole contract: to run these vectors against
// an implementation in another language, port this file — the op names, the
// shape of `in`, and the shape of `out` — and leave the vectors alone.
package conformance

import (
	"encoding/hex"
	"encoding/json"
	"fmt"
	"strconv"

	"github.com/middle-management/tailscreen/sdk/go/tailscreen"
)

// Case is one vector.
type Case struct {
	ID           string          `json:"id"`
	Requirements []string        `json:"requirements"`
	Op           string          `json:"op"`
	In           json.RawMessage `json:"in"`
	Out          json.RawMessage `json:"out"`
}

// Suite is one vector file.
type Suite struct {
	Suite       string `json:"suite"`
	Description string `json:"description"`
	Spec        string `json:"spec"`
	Cases       []Case `json:"cases"`
}

// Index is vectors/index.json.
type Index struct {
	SpecVersion int    `json:"specVersion"`
	Spec        string `json:"spec"`
	Generator   string `json:"generator"`
	Suites      []struct {
		Suite string `json:"suite"`
		File  string `json:"file"`
		Cases int    `json:"cases"`
	} `json:"suites"`
}

func unhex(s string) ([]byte, error) {
	if s == "" {
		return []byte{}, nil
	}
	return hex.DecodeString(s)
}

func mustHex(s string) []byte {
	b, err := unhex(s)
	if err != nil {
		panic(fmt.Sprintf("vector carries invalid hex %q: %v", s, err))
	}
	return b
}

// Run executes one case and returns the actual `out` object.
func Run(c Case) (map[string]any, error) {
	switch c.Op {

	// ---------------------------------------------------------------- UDP
	case "control.encodeSimple":
		var in struct{ Kind string }
		if err := json.Unmarshal(c.In, &in); err != nil {
			return nil, err
		}
		k, ok := tailscreen.ControlByName(in.Kind)
		if !ok {
			return nil, fmt.Errorf("unknown control name %q", in.Kind)
		}
		return map[string]any{"bytes": hex.EncodeToString(tailscreen.EncodeControl(k))}, nil

	case "control.decodeKind":
		var in struct{ Bytes string }
		if err := json.Unmarshal(c.In, &in); err != nil {
			return nil, err
		}
		k, ok := tailscreen.DecodeControl(mustHex(in.Bytes))
		if !ok {
			return map[string]any{"kind": nil}, nil
		}
		name, _ := tailscreen.ControlName(k)
		return map[string]any{"kind": name}, nil

	case "control.classify":
		var in struct{ Bytes string }
		if err := json.Unmarshal(c.In, &in); err != nil {
			return nil, err
		}
		var name string
		switch tailscreen.Classify(mustHex(in.Bytes)) {
		case tailscreen.ClassEmpty:
			name = "empty"
		case tailscreen.ClassRTP:
			name = "rtp"
		case tailscreen.ClassControl:
			name = "control"
		}
		return map[string]any{"class": name}, nil

	case "hello.encode":
		var in struct{ Caps tailscreen.Caps }
		if err := json.Unmarshal(c.In, &in); err != nil {
			return nil, err
		}
		return map[string]any{"bytes": hex.EncodeToString(tailscreen.EncodeHello(in.Caps))}, nil

	case "hello.decodeCaps":
		var in struct{ Bytes string }
		if err := json.Unmarshal(c.In, &in); err != nil {
			return nil, err
		}
		return map[string]any{"caps": tailscreen.DecodeHelloCaps(mustHex(in.Bytes))}, nil

	case "helloAck.encode":
		var in struct {
			SSRC uint32           `json:"ssrc"`
			Caps *tailscreen.Caps `json:"caps"`
		}
		if err := json.Unmarshal(c.In, &in); err != nil {
			return nil, err
		}
		return map[string]any{"bytes": hex.EncodeToString(tailscreen.EncodeHelloAck(in.SSRC, in.Caps))}, nil

	case "helloAck.decodeStrict":
		var in struct{ Bytes string }
		if err := json.Unmarshal(c.In, &in); err != nil {
			return nil, err
		}
		ssrc, ok := tailscreen.DecodeHelloAckStrict(mustHex(in.Bytes))
		if !ok {
			return map[string]any{"ssrc": nil}, nil
		}
		return map[string]any{"ssrc": ssrc}, nil

	case "helloAck.decodeTolerant":
		var in struct{ Bytes string }
		if err := json.Unmarshal(c.In, &in); err != nil {
			return nil, err
		}
		ssrc, caps, ok := tailscreen.DecodeHelloAckTolerant(mustHex(in.Bytes))
		if !ok {
			return map[string]any{"ssrc": nil, "caps": nil}, nil
		}
		return map[string]any{"ssrc": ssrc, "caps": caps}, nil

	// ------------------------------------------------------ loss recovery
	case "nack.encode":
		var in struct {
			Entries []tailscreen.NACKEntry `json:"entries"`
		}
		if err := json.Unmarshal(c.In, &in); err != nil {
			return nil, err
		}
		return map[string]any{"bytes": hex.EncodeToString(tailscreen.EncodeNACK(in.Entries))}, nil

	case "nack.decode":
		var in struct{ Bytes string }
		if err := json.Unmarshal(c.In, &in); err != nil {
			return nil, err
		}
		entries := tailscreen.DecodeNACK(mustHex(in.Bytes))
		if entries == nil {
			entries = []tailscreen.NACKEntry{}
		}
		return map[string]any{"entries": entries}, nil

	case "ping.encode":
		var in struct {
			ServerUptimeNs string `json:"serverUptimeNs"`
		}
		if err := json.Unmarshal(c.In, &in); err != nil {
			return nil, err
		}
		v, err := strconv.ParseUint(in.ServerUptimeNs, 10, 64)
		if err != nil {
			return nil, err
		}
		return map[string]any{"bytes": hex.EncodeToString(tailscreen.EncodePing(v))}, nil

	case "ping.decode":
		var in struct{ Bytes string }
		if err := json.Unmarshal(c.In, &in); err != nil {
			return nil, err
		}
		v, ok := tailscreen.DecodePing(mustHex(in.Bytes))
		if !ok {
			return map[string]any{"serverUptimeNs": nil}, nil
		}
		return map[string]any{"serverUptimeNs": strconv.FormatUint(v, 10)}, nil

	case "rr.encode":
		var in struct {
			Report                jsonReport `json:"report"`
			IncludeRecoveryFields bool       `json:"includeRecoveryFields"`
		}
		if err := json.Unmarshal(c.In, &in); err != nil {
			return nil, err
		}
		r, err := in.Report.toWire()
		if err != nil {
			return nil, err
		}
		return map[string]any{"bytes": hex.EncodeToString(tailscreen.EncodeReport(r, in.IncludeRecoveryFields))}, nil

	case "rr.decode":
		var in struct{ Bytes string }
		if err := json.Unmarshal(c.In, &in); err != nil {
			return nil, err
		}
		r, ok := tailscreen.DecodeReport(mustHex(in.Bytes))
		if !ok {
			return map[string]any{"report": nil}, nil
		}
		return map[string]any{"report": fromWireReport(r)}, nil

	case "fec.encodeDatagram":
		var in struct {
			BaseSeq uint16 `json:"baseSeq"`
			Count   int    `json:"count"`
			Body    string `json:"body"`
		}
		if err := json.Unmarshal(c.In, &in); err != nil {
			return nil, err
		}
		return map[string]any{"bytes": hex.EncodeToString(tailscreen.EncodeFEC(in.BaseSeq, in.Count, mustHex(in.Body)))}, nil

	case "fec.decodeDatagram":
		var in struct{ Bytes string }
		if err := json.Unmarshal(c.In, &in); err != nil {
			return nil, err
		}
		baseSeq, count, body, ok := tailscreen.DecodeFEC(mustHex(in.Bytes))
		if !ok {
			return map[string]any{"baseSeq": nil, "count": nil, "body": nil}, nil
		}
		return map[string]any{"baseSeq": baseSeq, "count": count, "body": hex.EncodeToString(body)}, nil

	case "fec.parity":
		var in struct {
			Packets []string `json:"packets"`
		}
		if err := json.Unmarshal(c.In, &in); err != nil {
			return nil, err
		}
		packets := make([][]byte, 0, len(in.Packets))
		for _, p := range in.Packets {
			packets = append(packets, mustHex(p))
		}
		return map[string]any{"body": hex.EncodeToString(tailscreen.ParityBody(packets))}, nil

	case "fec.recover":
		var in struct {
			MissingSeq uint16   `json:"missingSeq"`
			SSRC       uint32   `json:"ssrc"`
			Members    []string `json:"members"`
			Body       string   `json:"body"`
		}
		if err := json.Unmarshal(c.In, &in); err != nil {
			return nil, err
		}
		members := make([][]byte, 0, len(in.Members))
		for _, m := range in.Members {
			members = append(members, mustHex(m))
		}
		got := tailscreen.Recover(in.MissingSeq, in.SSRC, members, mustHex(in.Body))
		if got == nil {
			return map[string]any{"packet": nil}, nil
		}
		return map[string]any{"packet": hex.EncodeToString(got)}, nil

	// ---------------------------------------------------------------- RTP
	case "rtp.encodeHeader":
		var in struct {
			Marker      bool   `json:"marker"`
			PayloadType uint8  `json:"payloadType"`
			Sequence    uint16 `json:"sequenceNumber"`
			Timestamp   uint32 `json:"timestamp"`
			SSRC        uint32 `json:"ssrc"`
		}
		if err := json.Unmarshal(c.In, &in); err != nil {
			return nil, err
		}
		h := tailscreen.RTPHeader{
			Marker: in.Marker, PayloadType: in.PayloadType,
			Sequence: in.Sequence, Timestamp: in.Timestamp, SSRC: in.SSRC,
		}
		return map[string]any{"bytes": hex.EncodeToString(tailscreen.EncodeRTPHeader(h))}, nil

	case "rtp.decodeHeader":
		var in struct{ Bytes string }
		if err := json.Unmarshal(c.In, &in); err != nil {
			return nil, err
		}
		h, offset, ok := tailscreen.DecodeRTPHeader(mustHex(in.Bytes))
		if !ok {
			return map[string]any{"header": nil}, nil
		}
		return map[string]any{
			"marker":         h.Marker,
			"payloadType":    h.PayloadType,
			"sequenceNumber": h.Sequence,
			"timestamp":      h.Timestamp,
			"ssrc":           h.SSRC,
			"payloadOffset":  offset,
		}, nil

	case "packetize.h264", "packetize.hevc":
		var in struct {
			NALs          []string `json:"nals"`
			Timestamp     uint32   `json:"timestamp"`
			SSRC          uint32   `json:"ssrc"`
			StartSequence uint16   `json:"startSequence"`
		}
		if err := json.Unmarshal(c.In, &in); err != nil {
			return nil, err
		}
		nals := make([][]byte, 0, len(in.NALs))
		for _, n := range in.NALs {
			nals = append(nals, mustHex(n))
		}
		var packets [][]byte
		if c.Op == "packetize.h264" {
			packets = tailscreen.PacketizeH264(nals, in.Timestamp, in.SSRC, in.StartSequence)
		} else {
			packets = tailscreen.PacketizeHEVC(nals, in.Timestamp, in.SSRC, in.StartSequence)
		}
		out := make([]string, 0, len(packets))
		for _, p := range packets {
			out = append(out, hex.EncodeToString(p))
		}
		return map[string]any{"packets": out}, nil

	// ---------------------------------------------------------- TCP frames
	case "frame.encode":
		var in struct {
			Type    uint8  `json:"type"`
			Payload string `json:"payload"`
		}
		if err := json.Unmarshal(c.In, &in); err != nil {
			return nil, err
		}
		b := tailscreen.EncodeFrame(tailscreen.MessageType(in.Type), mustHex(in.Payload))
		return map[string]any{"bytes": hex.EncodeToString(b)}, nil

	case "frame.parse":
		var in struct {
			Chunks []string `json:"chunks"`
		}
		if err := json.Unmarshal(c.In, &in); err != nil {
			return nil, err
		}
		var p tailscreen.FrameParser
		frames := []map[string]any{}
		for _, chunk := range in.Chunks {
			p.Append(mustHex(chunk))
			for _, f := range p.Drain() {
				frames = append(frames, map[string]any{
					"type":    uint8(f.Type),
					"payload": hex.EncodeToString(f.Payload),
				})
			}
		}
		return map[string]any{"frames": frames, "corrupt": p.Corrupt()}, nil

	// ------------------------------------------------------- JSON payloads
	case "json.inputEvent.decode":
		var in struct {
			JSON string `json:"json"`
		}
		if err := json.Unmarshal(c.In, &in); err != nil {
			return nil, err
		}
		ev, err := tailscreen.DecodeInputEvent([]byte(in.JSON))
		if err != nil {
			return map[string]any{"event": nil}, nil
		}
		return map[string]any{"event": inputEventOut(ev)}, nil

	case "json.annotationOp.decode":
		var in struct {
			JSON string `json:"json"`
		}
		if err := json.Unmarshal(c.In, &in); err != nil {
			return nil, err
		}
		op, err := tailscreen.DecodeAnnotationOp([]byte(in.JSON))
		if err != nil {
			return map[string]any{"op": nil}, nil
		}
		return map[string]any{"op": annotationOut(op)}, nil

	case "json.requestToShare.decode":
		var in struct {
			JSON string `json:"json"`
		}
		if err := json.Unmarshal(c.In, &in); err != nil {
			return nil, err
		}
		host, err := tailscreen.DecodeRequestToShare([]byte(in.JSON))
		if err != nil {
			return map[string]any{"fromHostname": nil}, nil
		}
		return map[string]any{"fromHostname": host}, nil

	case "json.shareResponse.decode":
		var in struct {
			JSON string `json:"json"`
		}
		if err := json.Unmarshal(c.In, &in); err != nil {
			return nil, err
		}
		accepted, err := tailscreen.DecodeShareResponse([]byte(in.JSON))
		if err != nil {
			return map[string]any{"accepted": nil}, nil
		}
		return map[string]any{"accepted": accepted}, nil

	case "json.controlRevoked.decode":
		var in struct {
			JSON string `json:"json"`
		}
		if err := json.Unmarshal(c.In, &in); err != nil {
			return nil, err
		}
		return map[string]any{"reason": tailscreen.DecodeControlRevoked([]byte(in.JSON))}, nil

	case "json.metadata.decode":
		var in struct {
			JSON string `json:"json"`
		}
		if err := json.Unmarshal(c.In, &in); err != nil {
			return nil, err
		}
		md, err := tailscreen.DecodeMetadata([]byte(in.JSON))
		if err != nil {
			return map[string]any{"metadata": nil}, nil
		}
		var codec any
		if md.VideoCodec != nil {
			codec = *md.VideoCodec
		}
		return map[string]any{"metadata": map[string]any{
			"version":    md.Version,
			"shareName":  md.ShareName,
			"hostname":   md.Hostname,
			"width":      md.Width,
			"height":     md.Height,
			"isSharing":  md.IsSharing,
			"timestamp":  md.Timestamp,
			"videoCodec": codec,
		}}, nil
	}

	return nil, fmt.Errorf("unimplemented op %q", c.Op)
}

// jsonReport mirrors the receiver report as the vectors carry it: the 64-bit
// ping echo travels as a decimal string, because JSON numbers lose precision
// above 2^53 and this field is a nanosecond clock.
type jsonReport struct {
	FracLostQ8       uint8  `json:"fracLostQ8"`
	ExtHighestSeq    uint32 `json:"extHighestSeq"`
	JitterTicks      uint32 `json:"jitterTicks"`
	LastPingTs       string `json:"lastPingTs"`
	DelaySincePingMs uint16 `json:"delaySincePingMs"`
	FECRecovered     uint16 `json:"fecRecovered"`
	NACKRecovered    uint16 `json:"nackRecovered"`
}

func (j jsonReport) toWire() (tailscreen.Report, error) {
	ts, err := strconv.ParseUint(j.LastPingTs, 10, 64)
	if err != nil {
		return tailscreen.Report{}, err
	}
	return tailscreen.Report{
		FracLostQ8: j.FracLostQ8, ExtHighestSeq: j.ExtHighestSeq,
		JitterTicks: j.JitterTicks, LastPingTs: ts,
		DelaySincePingMs: j.DelaySincePingMs,
		FECRecovered:     j.FECRecovered, NACKRecovered: j.NACKRecovered,
	}, nil
}

func fromWireReport(r tailscreen.Report) map[string]any {
	return map[string]any{
		"fracLostQ8":       r.FracLostQ8,
		"extHighestSeq":    r.ExtHighestSeq,
		"jitterTicks":      r.JitterTicks,
		"lastPingTs":       strconv.FormatUint(r.LastPingTs, 10),
		"delaySincePingMs": r.DelaySincePingMs,
		"fecRecovered":     r.FECRecovered,
		"nackRecovered":    r.NACKRecovered,
	}
}

func inputEventOut(ev tailscreen.InputEvent) map[string]any {
	switch ev.Kind {
	case "mouseMove":
		return map[string]any{"kind": ev.Kind, "x": ev.X, "y": ev.Y}
	case "mouseDown", "mouseUp":
		return map[string]any{
			"kind": ev.Kind, "x": ev.X, "y": ev.Y,
			"button": ev.Button, "modifiers": ev.Modifiers,
		}
	case "scroll":
		return map[string]any{
			"kind": ev.Kind, "x": ev.X, "y": ev.Y,
			"deltaX": ev.DeltaX, "deltaY": ev.DeltaY, "modifiers": ev.Modifiers,
		}
	default: // keyDown, keyUp
		return map[string]any{"kind": ev.Kind, "key": ev.Key, "modifiers": ev.Modifiers}
	}
}

func annotationOut(op tailscreen.AnnotationOp) map[string]any {
	switch op.Kind {
	case "clearAll":
		return map[string]any{"kind": op.Kind}
	case "undo":
		return map[string]any{"kind": op.Kind, "id": op.ID}
	default:
		points := make([][]float64, 0, len(op.Points))
		for _, p := range op.Points {
			points = append(points, []float64{p[0], p[1]})
		}
		return map[string]any{
			"kind": op.Kind, "id": op.ID, "tool": op.Tool,
			"points": points,
			"color": map[string]any{
				"r": op.Color.R, "g": op.Color.G, "b": op.Color.B, "a": op.Color.A,
			},
			"width": op.Width,
		}
	}
}
