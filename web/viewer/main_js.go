//go:build js && wasm

// Command viewer is the browser viewer's wasm core. Phase 2 of
// plans/browser-viewer.md: transport only — it proves a browser can dial a
// share by token through the guest tunnel and move the stream profile's
// framed datagrams both ways. Decoding (Phase 3) is not here yet.
//
// It exports a deliberately small surface onto globalThis; the page owns the
// loop (dial → HELLO → KEEPALIVE cadence → classify what comes back):
//
//	tailscreenGuestDial(token, port?) → Promise<Conn>
//	    Conn = { serverAddr, publicKey,
//	             read()  → Promise<Uint8Array | null>   (null = EOF)
//	             write(Uint8Array) → Promise<number>
//	             close() → Promise<void> }
//	tailscreenFrameEncode(type, payload?)  → Uint8Array   (§10 framing)
//	tailscreenNewFrameParser()             → { append(u8), next() → {type, payload} | null, corrupt() }
//	tailscreenHello(caps?)                 → Uint8Array   (legacy 1-byte HELLO when caps is 0/absent)
//	tailscreenControl(name)                → Uint8Array   ("keepalive", "pli", "bye", …)
//	tailscreenClassify(u8)                 → { class, kind?, name?, pt?, seq?, ts?, ssrc?, marker? }
//	tailscreenConstants                    → { port, mediaDatagramType, keepaliveMs, idleTimeoutMs, pt: {…} }
//
// Everything that touches bytes takes and returns Uint8Array. The protocol
// codecs are sdk/go — the same code the conformance vectors pin — so the page
// never re-implements a wire format.
package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"syscall/js"
	"time"

	"github.com/middle-management/tailscreen/sdk/go/tailscreen"
	"github.com/tailscale/libtailscale/guest"
)

func main() {
	g := js.Global()
	g.Set("tailscreenGuestDial", js.FuncOf(guestDialJS))
	g.Set("tailscreenFrameEncode", js.FuncOf(frameEncodeJS))
	g.Set("tailscreenNewFrameParser", js.FuncOf(newFrameParserJS))
	g.Set("tailscreenHello", js.FuncOf(helloJS))
	g.Set("tailscreenControl", js.FuncOf(controlJS))
	g.Set("tailscreenClassify", js.FuncOf(classifyJS))
	g.Set("tailscreenConstants", js.ValueOf(map[string]any{
		"port":              tailscreen.Port,
		"mediaDatagramType": int(tailscreen.MsgMediaDatagram),
		"keepaliveMs":       int(tailscreen.KeepaliveInterval / time.Millisecond),
		"idleTimeoutMs":     int(tailscreen.IdleTimeout / time.Millisecond),
		"pt": map[string]any{
			"h264":        tailscreen.PTH264,
			"hevc":        tailscreen.PTHEVC,
			"voice":       tailscreen.PTVoice,
			"systemAudio": tailscreen.PTSystemAudio,
		},
	}))
	// Set last: the page polls for it. Exports live as long as this
	// goroutine, which never returns.
	g.Set("tailscreenReady", true)
	select {}
}

// --- byte marshalling --------------------------------------------------------

func toBytes(v js.Value) []byte {
	if v.IsUndefined() || v.IsNull() {
		return nil
	}
	b := make([]byte, v.Get("byteLength").Int())
	js.CopyBytesToGo(b, v)
	return b
}

func toU8(b []byte) js.Value {
	a := js.Global().Get("Uint8Array").New(len(b))
	js.CopyBytesToJS(a, b)
	return a
}

// makePromise runs f on a goroutine and resolves (or rejects with the
// error's text) a JS Promise with its result. A js.FuncOf callback must not
// block, so every operation that can wait on the network goes through here.
func makePromise(f func() (any, error)) js.Value {
	handler := js.FuncOf(func(this js.Value, args []js.Value) any {
		resolve, reject := args[0], args[1]
		go func() {
			res, err := f()
			if err != nil {
				reject.Invoke(err.Error())
				return
			}
			resolve.Invoke(res)
		}()
		return nil
	})
	return js.Global().Get("Promise").New(handler)
}

func consoleLogf(format string, args ...any) {
	js.Global().Get("console").Call("log", "[guest] "+fmt.Sprintf(format, args...))
}

// --- the tunnel ----------------------------------------------------------------

func guestDialJS(this js.Value, args []js.Value) any {
	if len(args) < 1 || args[0].Type() != js.TypeString {
		return makePromise(func() (any, error) { return nil, errors.New("tailscreenGuestDial: token required") })
	}
	token := args[0].String()
	port := uint16(tailscreen.Port)
	if len(args) > 1 && args[1].Type() == js.TypeNumber {
		port = uint16(args[1].Int())
	}
	return makePromise(func() (any, error) {
		ci, err := guest.ParseConnBlob(guest.ConnBlob(token))
		if err != nil {
			return nil, fmt.Errorf("parse token: %w", err)
		}
		c := guest.NewClient(guest.ConnBlob(token))
		c.Logf = consoleLogf
		// Generous: the first dial does the DERP handshake and the
		// WireGuard bring-up, all relayed. Direct paths never happen in a
		// browser (no UDP), so there is nothing to wait for beyond the relay.
		ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
		defer cancel()
		conn, err := c.DialTCPPort(ctx, port)
		if err != nil {
			c.Close()
			return nil, fmt.Errorf("dial tcp/%d through the tunnel: %w", port, err)
		}
		return newConnObject(c, conn, guest.AddrForKey(ci.ServerPublic.NodePublic).String()), nil
	})
}

func newConnObject(c *guest.Client, conn net.Conn, serverAddr string) map[string]any {
	return map[string]any{
		"serverAddr": serverAddr,
		"publicKey":  c.PublicKey().String(),
		"read": js.FuncOf(func(this js.Value, args []js.Value) any {
			return makePromise(func() (any, error) {
				buf := make([]byte, 64<<10)
				n, err := conn.Read(buf)
				if n > 0 {
					return toU8(buf[:n]), nil
				}
				if err == nil || errors.Is(err, io.EOF) {
					return js.Null(), nil
				}
				return nil, err
			})
		}),
		"write": js.FuncOf(func(this js.Value, args []js.Value) any {
			// Copy while still on the JS side: the goroutine below runs
			// after this callback returns and the caller may reuse the array.
			var data []byte
			if len(args) > 0 {
				data = toBytes(args[0])
			}
			return makePromise(func() (any, error) {
				n, err := conn.Write(data)
				return n, err
			})
		}),
		"close": js.FuncOf(func(this js.Value, args []js.Value) any {
			return makePromise(func() (any, error) {
				conn.Close()
				return nil, c.Close()
			})
		}),
	}
}

// --- the wire, via sdk/go ---------------------------------------------------------

func frameEncodeJS(this js.Value, args []js.Value) any {
	if len(args) < 1 {
		return js.Null()
	}
	var payload []byte
	if len(args) > 1 {
		payload = toBytes(args[1])
	}
	return toU8(tailscreen.EncodeFrame(tailscreen.MessageType(args[0].Int()), payload))
}

func newFrameParserJS(this js.Value, args []js.Value) any {
	p := &tailscreen.FrameParser{}
	return map[string]any{
		"append": js.FuncOf(func(this js.Value, args []js.Value) any {
			if len(args) > 0 {
				p.Append(toBytes(args[0]))
			}
			return nil
		}),
		"next": js.FuncOf(func(this js.Value, args []js.Value) any {
			f, ok := p.Next()
			if !ok {
				return js.Null()
			}
			return map[string]any{"type": int(f.Type), "payload": toU8(f.Payload)}
		}),
		"corrupt": js.FuncOf(func(this js.Value, args []js.Value) any {
			return p.Corrupt()
		}),
	}
}

func helloJS(this js.Value, args []js.Value) any {
	caps := tailscreen.Caps(0)
	if len(args) > 0 && args[0].Type() == js.TypeNumber {
		caps = tailscreen.Caps(args[0].Int())
	}
	if caps == 0 {
		return toU8(tailscreen.EncodeControl(tailscreen.Hello))
	}
	return toU8(tailscreen.EncodeHello(caps))
}

func controlJS(this js.Value, args []js.Value) any {
	if len(args) < 1 {
		return js.Null()
	}
	k, ok := tailscreen.ControlByName(args[0].String())
	if !ok {
		return js.Null()
	}
	return toU8(tailscreen.EncodeControl(k))
}

func classifyJS(this js.Value, args []js.Value) any {
	var b []byte
	if len(args) > 0 {
		b = toBytes(args[0])
	}
	switch tailscreen.Classify(b) {
	case tailscreen.ClassEmpty:
		return map[string]any{"class": "empty"}
	case tailscreen.ClassRTP:
		h, _, ok := tailscreen.DecodeRTPHeader(b)
		if !ok {
			return map[string]any{"class": "rtp", "malformed": true}
		}
		return map[string]any{
			"class": "rtp", "pt": int(h.PayloadType), "seq": int(h.Sequence),
			"ts": int64(h.Timestamp), "ssrc": int64(h.SSRC), "marker": h.Marker,
		}
	default:
		k, ok := tailscreen.DecodeControl(b)
		if !ok {
			return map[string]any{"class": "control", "unknown": true, "kind": int(b[0])}
		}
		name, _ := tailscreen.ControlName(k)
		out := map[string]any{"class": "control", "kind": int(k), "name": name}
		if k == tailscreen.HelloAck {
			if ssrc, caps, ok := tailscreen.DecodeHelloAckTolerant(b); ok {
				out["ssrc"] = int64(ssrc)
				out["serverCaps"] = int(caps)
			}
		}
		return out
	}
}
