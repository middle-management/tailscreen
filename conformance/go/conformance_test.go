package conformance

import (
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"strings"
	"testing"

	"github.com/middle-management/tailscreen/sdk/go/tailscreen"
)

const vectorDir = "../vectors"

func loadIndex(t *testing.T) Index {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join(vectorDir, "index.json"))
	if err != nil {
		t.Fatalf("reading vector index: %v", err)
	}
	var idx Index
	if err := json.Unmarshal(raw, &idx); err != nil {
		t.Fatalf("parsing vector index: %v", err)
	}
	return idx
}

func loadSuite(t *testing.T, file string) Suite {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join(vectorDir, file))
	if err != nil {
		t.Fatalf("reading %s: %v", file, err)
	}
	var s Suite
	if err := json.Unmarshal(raw, &s); err != nil {
		t.Fatalf("parsing %s: %v", file, err)
	}
	return s
}

// normalize round-trips a value through JSON so that both sides of a
// comparison use the same representation for every number (float64) and the
// same spelling for absence (nil). Without it a uint16 result would never
// compare equal to the float64 a vector decodes to.
func normalize(t *testing.T, v any) any {
	t.Helper()
	raw, err := json.Marshal(v)
	if err != nil {
		t.Fatalf("marshalling result: %v", err)
	}
	var out any
	if err := json.Unmarshal(raw, &out); err != nil {
		t.Fatalf("normalizing result: %v", err)
	}
	return out
}

func TestVectors(t *testing.T) {
	idx := loadIndex(t)
	if idx.SpecVersion != 1 {
		t.Fatalf("vectors declare spec version %d, this runner implements 1", idx.SpecVersion)
	}
	if len(idx.Suites) == 0 {
		t.Fatal("vector index lists no suites")
	}

	total := 0
	for _, entry := range idx.Suites {
		suite := loadSuite(t, entry.File)
		if len(suite.Cases) != entry.Cases {
			t.Errorf("%s: index claims %d cases, file has %d", entry.File, entry.Cases, len(suite.Cases))
		}
		t.Run(suite.Suite, func(t *testing.T) {
			for _, c := range suite.Cases {
				c := c
				t.Run(strings.TrimPrefix(c.ID, suite.Suite+"/"), func(t *testing.T) {
					got, err := Run(c)
					if err != nil {
						t.Fatalf("%s [%s]: %v", c.ID, strings.Join(c.Requirements, ", "), err)
					}
					var want any
					if err := json.Unmarshal(c.Out, &want); err != nil {
						t.Fatalf("%s: expected output is not valid JSON: %v", c.ID, err)
					}
					gotN := normalize(t, got)
					if !reflect.DeepEqual(gotN, want) {
						gotJSON, _ := json.MarshalIndent(gotN, "", "  ")
						wantJSON, _ := json.MarshalIndent(want, "", "  ")
						t.Errorf("%s violates %s\n  op:   %s\n  want: %s\n  got:  %s",
							c.ID, strings.Join(c.Requirements, ", "), c.Op, wantJSON, gotJSON)
					}
				})
			}
		})
		total += len(suite.Cases)
	}
	t.Logf("ran %d conformance vectors across %d suites", total, len(idx.Suites))
}

// TestEveryCaseCitesARequirement keeps the vectors tied to the specification:
// a case that cites nothing cannot tell you what broke when it fails.
func TestEveryCaseCitesARequirement(t *testing.T) {
	for _, entry := range loadIndex(t).Suites {
		for _, c := range loadSuite(t, entry.File).Cases {
			if len(c.Requirements) == 0 {
				t.Errorf("%s cites no requirement", c.ID)
			}
			for _, r := range c.Requirements {
				if !strings.HasPrefix(r, "TS-") {
					t.Errorf("%s cites %q, which is not a requirement identifier", c.ID, r)
				}
			}
		}
	}
}

// TestRequirementsExistInSpec catches a vector citing an identifier the
// specification does not define — a typo, or a requirement that was renamed
// without its vectors following.
func TestRequirementsExistInSpec(t *testing.T) {
	spec, err := os.ReadFile("../../docs/spec.md")
	if err != nil {
		t.Skipf("specification not readable from here: %v", err)
	}
	text := string(spec)

	missing := map[string][]string{}
	for _, entry := range loadIndex(t).Suites {
		for _, c := range loadSuite(t, entry.File).Cases {
			for _, r := range c.Requirements {
				if !strings.Contains(text, "**"+r+"**") {
					missing[r] = append(missing[r], c.ID)
				}
			}
		}
	}
	if len(missing) == 0 {
		return
	}
	keys := make([]string, 0, len(missing))
	for k := range missing {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for _, k := range keys {
		t.Errorf("vectors cite %s, which docs/spec.md does not define (e.g. %s)", k, missing[k][0])
	}
}

// TestVectorsCoverEveryWireValue is the registry leg: every assigned UDP
// control byte AND every assigned TCP message type must be exercised by some
// vector, so a new wire value cannot ship without one (TS-CNF-002).
func TestVectorsCoverEveryWireValue(t *testing.T) {
	seenControl := map[string]bool{}
	seenTCP := map[int]bool{}

	// The two multi-key JSON payload types (inputEvent, metadataResponse)
	// cannot ride a frame.parse vector byte-identically — the Swift runner
	// re-encodes payloads, and JSON object key order is not stable across
	// implementations (see conformance/README.md) — so their payload-level
	// ops stand in for their framing coverage.
	payloadOps := map[string]int{
		"json.annotationOp.decode":   0x03,
		"json.requestToShare.decode": 0x04,
		"json.shareResponse.decode":  0x05,
		"json.controlRevoked.decode": 0x08,
		"json.inputEvent.decode":     0x09,
		"json.metadata.decode":       0x0C,
	}

	for _, entry := range loadIndex(t).Suites {
		for _, c := range loadSuite(t, entry.File).Cases {
			if typ, ok := payloadOps[c.Op]; ok {
				seenTCP[typ] = true
			}
			var in map[string]any
			if err := json.Unmarshal(c.In, &in); err == nil {
				if kind, ok := in["kind"].(string); ok {
					seenControl[kind] = true
				}
				if typ, ok := in["type"].(float64); ok && c.Op == "frame.encode" {
					seenTCP[int(typ)] = true
				}
			}
			for _, typ := range asFrames(c.Out) {
				seenTCP[typ] = true
			}
		}
	}

	for _, name := range []string{
		"hello", "keepalive", "bye", "pli", "helloAck", "serverBye",
		"helloPending", "codecUnsupported", "helloDenied", "profileUnsupported",
		"nack", "receiverReport", "ping", "fec",
	} {
		if !seenControl[name] {
			t.Errorf("no vector exercises control message %s", name)
		}
	}
	// The assigned TCP message-type range — spec Appendix A.2.
	for typ := 0x03; typ <= 0x0C; typ++ {
		if !seenTCP[typ] {
			t.Errorf("no vector exercises TCP message type %#02x", typ)
		}
	}
}

// TestVectorsCoverEveryCapabilityBit is the same registry leg for the other
// half of the wire's assigned values — the capability bits of Appendix A.3,
// which the control-byte sweep above cannot see because they ride inside a
// HELLO's second byte rather than as a message of their own. Without it a new
// bit can ship with no vector at all, which is exactly how tenBit (bit 5)
// nearly did.
func TestVectorsCoverEveryCapabilityBit(t *testing.T) {
	var seen tailscreen.Caps
	note := func(raw json.RawMessage) {
		var fields map[string]any
		if err := json.Unmarshal(raw, &fields); err != nil {
			return
		}
		if caps, ok := fields["caps"].(float64); ok {
			seen |= tailscreen.Caps(uint8(caps))
		}
	}
	for _, entry := range loadIndex(t).Suites {
		for _, c := range loadSuite(t, entry.File).Cases {
			note(c.In)
			note(c.Out)
		}
	}
	for _, bit := range []struct {
		name string
		cap  tailscreen.Caps
	}{
		{"nack", tailscreen.CapNACK},
		{"receiverReport", tailscreen.CapReceiverReport},
		{"fec", tailscreen.CapFEC},
		{"remoteControl", tailscreen.CapRemoteControl},
		{"annotations", tailscreen.CapAnnotations},
		{"tenBit", tailscreen.CapTenBit},
	} {
		if !seen.Has(bit.cap) {
			t.Errorf("no vector exercises capability bit %s (%#02x)", bit.name, uint8(bit.cap))
		}
	}
}

func asFrames(out json.RawMessage) []int {
	var o struct {
		Frames []struct {
			Type int `json:"type"`
		} `json:"frames"`
	}
	if err := json.Unmarshal(out, &o); err != nil {
		return nil
	}
	types := make([]int, 0, len(o.Frames))
	for _, f := range o.Frames {
		types = append(types, f.Type)
	}
	return types
}
