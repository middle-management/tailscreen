package tailscreen

import (
	"encoding/json"
	"errors"
	"fmt"
	"regexp"
	"strings"
)

// Clamps applied to peer-supplied display strings — spec §10.2, TS-TCP-023.
// They are applied by the parser, before the value reaches anything that
// renders it, because these strings are attacker-controlled.
const (
	MaxHostnameChars      = 64
	MaxReasonChars        = 128
	MaxDisplayStringChars = 128
)

// clamp truncates to at most n characters. The vectors use ASCII only; on
// non-ASCII input an implementation MUST NOT split a user-perceived
// character, so this counts runes rather than bytes.
func clamp(s string, n int) string {
	r := []rune(s)
	if len(r) <= n {
		return s
	}
	return string(r[:n])
}

var errMalformed = errors.New("malformed payload")

// ---------------------------------------------------------------------------
// Input events — spec §12.2
// ---------------------------------------------------------------------------

// InputEvent is one viewer→sharer input event. Coordinates are normalized to
// [0,1] with the origin top-left (TS-RMT-020); Key is a USB HID keyboard-page
// usage (TS-RMT-022); Modifiers is the five-bit neutral set (TS-RMT-023).
type InputEvent struct {
	Kind      string
	X, Y      float64
	DeltaX    float64
	DeltaY    float64
	Button    string
	Key       uint16
	Modifiers uint16
}

var validButtons = map[string]bool{"left": true, "right": true, "middle": true}

// DecodeInputEvent parses an inputEvent payload. It rejects the frame — it
// does not clamp or substitute — when a coordinate is NaN, an infinity, or
// out of range (TS-RMT-029), when the button is not one of the three
// (TS-RMT-021), and when the case is one it does not know (TS-TCP-008).
//
// Rejecting NaN at the parser is the first line of defence: a NaN that
// reaches coordinate mapping has no safe interpretation.
func DecodeInputEvent(payload []byte) (InputEvent, error) {
	var outer map[string]json.RawMessage
	if err := json.Unmarshal(payload, &outer); err != nil {
		return InputEvent{}, errMalformed
	}
	if len(outer) != 1 {
		return InputEvent{}, errMalformed
	}
	var kind string
	var body json.RawMessage
	for k, v := range outer {
		kind, body = k, v
	}

	type fields struct {
		X         *float64 `json:"x"`
		Y         *float64 `json:"y"`
		DeltaX    *float64 `json:"deltaX"`
		DeltaY    *float64 `json:"deltaY"`
		Button    *string  `json:"button"`
		Key       *uint16  `json:"key"`
		Modifiers *uint16  `json:"modifiers"`
	}
	var f fields
	// Go's decoder rejects the NaN/Infinity tokens as invalid JSON and an
	// out-of-range literal such as 1e999 as an unrepresentable number, which
	// is exactly the behaviour TS-RMT-029 requires.
	if err := json.Unmarshal(body, &f); err != nil {
		return InputEvent{}, errMalformed
	}

	ev := InputEvent{Kind: kind}
	switch kind {
	case "mouseMove":
		if f.X == nil || f.Y == nil {
			return InputEvent{}, errMalformed
		}
		ev.X, ev.Y = *f.X, *f.Y
	case "mouseDown", "mouseUp":
		if f.X == nil || f.Y == nil || f.Button == nil || f.Modifiers == nil {
			return InputEvent{}, errMalformed
		}
		if !validButtons[*f.Button] {
			return InputEvent{}, errMalformed
		}
		ev.X, ev.Y, ev.Button, ev.Modifiers = *f.X, *f.Y, *f.Button, *f.Modifiers
	case "scroll":
		if f.X == nil || f.Y == nil || f.DeltaX == nil || f.DeltaY == nil || f.Modifiers == nil {
			return InputEvent{}, errMalformed
		}
		ev.X, ev.Y, ev.DeltaX, ev.DeltaY, ev.Modifiers = *f.X, *f.Y, *f.DeltaX, *f.DeltaY, *f.Modifiers
	case "keyDown", "keyUp":
		if f.Key == nil || f.Modifiers == nil {
			return InputEvent{}, errMalformed
		}
		ev.Key, ev.Modifiers = *f.Key, *f.Modifiers
	default:
		return InputEvent{}, errMalformed
	}
	return ev, nil
}

// ---------------------------------------------------------------------------
// Annotations — spec §11
// ---------------------------------------------------------------------------

var validTools = map[string]bool{
	"pen": true, "line": true, "arrow": true,
	"rectangle": true, "oval": true, "click": true,
}

var uuidPattern = regexp.MustCompile(`^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$`)

// RGBA is a stroke colour in sRGB components.
type RGBA struct {
	R float64 `json:"r"`
	G float64 `json:"g"`
	B float64 `json:"b"`
	A float64 `json:"a"`
}

// AnnotationOp is one operation on the shared canvas.
type AnnotationOp struct {
	Kind   string // add | undo | clearAll
	ID     string
	Tool   string
	Points [][2]float64
	Color  RGBA
	Width  float64
}

// DecodeAnnotationOp parses an annotation payload. A point is a two-element
// array (TS-ANN-002); a tool this implementation does not know is a rejected
// operation, not a rejected connection (TS-ANN-003).
func DecodeAnnotationOp(payload []byte) (AnnotationOp, error) {
	var env struct {
		Type       *string `json:"type"`
		ID         *string `json:"id"`
		Annotation *struct {
			ID     *string       `json:"id"`
			Tool   *string       `json:"tool"`
			Points *[][2]float64 `json:"points"`
			Color  *RGBA         `json:"color"`
			Width  *float64      `json:"width"`
		} `json:"annotation"`
	}
	if err := json.Unmarshal(payload, &env); err != nil || env.Type == nil {
		return AnnotationOp{}, errMalformed
	}
	switch *env.Type {
	case "clearAll":
		return AnnotationOp{Kind: "clearAll"}, nil
	case "undo":
		if env.ID == nil || !uuidPattern.MatchString(*env.ID) {
			return AnnotationOp{}, errMalformed
		}
		return AnnotationOp{Kind: "undo", ID: strings.ToUpper(*env.ID)}, nil
	case "add":
		a := env.Annotation
		if a == nil || a.ID == nil || a.Tool == nil || a.Points == nil || a.Color == nil || a.Width == nil {
			return AnnotationOp{}, errMalformed
		}
		if !uuidPattern.MatchString(*a.ID) || !validTools[*a.Tool] {
			return AnnotationOp{}, errMalformed
		}
		return AnnotationOp{
			Kind:   "add",
			ID:     strings.ToUpper(*a.ID),
			Tool:   *a.Tool,
			Points: *a.Points,
			Color:  *a.Color,
			Width:  *a.Width,
		}, nil
	default:
		return AnnotationOp{}, errMalformed
	}
}

// ---------------------------------------------------------------------------
// Request to share, share response, control revoked — spec §10.2, §13.1
// ---------------------------------------------------------------------------

// DecodeRequestToShare parses a requestToShare payload, clamping the
// peer-supplied hostname (TS-TCP-023).
func DecodeRequestToShare(payload []byte) (string, error) {
	var p struct {
		FromHostname *string `json:"fromHostname"`
	}
	if err := json.Unmarshal(payload, &p); err != nil || p.FromHostname == nil {
		return "", errMalformed
	}
	return clamp(*p.FromHostname, MaxHostnameChars), nil
}

// DecodeShareResponse parses a shareResponse payload. A request payload
// arriving inside a response frame is malformed and MUST be dropped, not
// reinterpreted.
func DecodeShareResponse(payload []byte) (bool, error) {
	var p struct {
		Type *string `json:"type"`
	}
	if err := json.Unmarshal(payload, &p); err != nil || p.Type == nil {
		return false, errMalformed
	}
	switch *p.Type {
	case "acceptShare":
		return true, nil
	case "declineShare":
		return false, nil
	default:
		return false, errMalformed
	}
}

// DecodeControlRevoked parses a controlRevoked payload. An empty or
// undecodable payload is tolerated as a bare revoke with no reason
// (TS-TCP-024) — the grant is gone either way, and refusing to parse the
// reason must not leave the viewer believing it still has control.
func DecodeControlRevoked(payload []byte) string {
	if len(payload) == 0 {
		return ""
	}
	var p struct {
		Reason *string `json:"reason"`
	}
	if err := json.Unmarshal(payload, &p); err != nil || p.Reason == nil {
		return ""
	}
	return clamp(*p.Reason, MaxReasonChars)
}

// ---------------------------------------------------------------------------
// Metadata — spec §10.2, §13.2
// ---------------------------------------------------------------------------

// Metadata is the peer self-description answered to a metadataRequest.
type Metadata struct {
	Version    string
	ShareName  string
	Hostname   string
	Width      int
	Height     int
	IsSharing  bool
	Timestamp  float64 // seconds since 2001-01-01T00:00:00Z — TS-TCP-020
	VideoCodec *string // absent means H.264 — TS-TCP-021
}

// DecodeMetadata parses a metadataResponse payload, clamping the two display
// strings (TS-TCP-023). An absent videoCodec is not an error.
func DecodeMetadata(payload []byte) (Metadata, error) {
	var p struct {
		Version    *string  `json:"version"`
		ShareName  *string  `json:"shareName"`
		Hostname   *string  `json:"hostname"`
		IsSharing  *bool    `json:"isSharing"`
		Timestamp  *float64 `json:"timestamp"`
		VideoCodec *string  `json:"videoCodec"`
		Resolution *struct {
			Width  *int `json:"width"`
			Height *int `json:"height"`
		} `json:"screenResolution"`
	}
	if err := json.Unmarshal(payload, &p); err != nil {
		return Metadata{}, errMalformed
	}
	if p.Version == nil || p.ShareName == nil || p.Hostname == nil ||
		p.IsSharing == nil || p.Timestamp == nil || p.Resolution == nil ||
		p.Resolution.Width == nil || p.Resolution.Height == nil {
		return Metadata{}, errMalformed
	}
	if p.VideoCodec != nil && *p.VideoCodec != "h264" && *p.VideoCodec != "hevc" {
		return Metadata{}, fmt.Errorf("%w: unknown codec %q", errMalformed, *p.VideoCodec)
	}
	return Metadata{
		Version:    *p.Version,
		ShareName:  clamp(*p.ShareName, MaxDisplayStringChars),
		Hostname:   clamp(*p.Hostname, MaxDisplayStringChars),
		Width:      *p.Resolution.Width,
		Height:     *p.Resolution.Height,
		IsSharing:  *p.IsSharing,
		Timestamp:  *p.Timestamp,
		VideoCodec: p.VideoCodec,
	}, nil
}
