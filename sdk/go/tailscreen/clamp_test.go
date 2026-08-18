package tailscreen

import "testing"

func TestClampCountsUserPerceivedCharacters(t *testing.T) {
	cases := []struct {
		name  string
		in    string
		limit int
		want  string
	}{
		{"ascii under the limit is untouched", "studio-imac", 64, "studio-imac"},
		{"ascii at the limit is untouched", "aaaa", 4, "aaaa"},
		{"ascii over the limit truncates", "abcdef", 4, "abcd"},
		{"zero limit yields empty", "abc", 0, ""},
		// One user-perceived character built from two runes: e + U+0301.
		// A rune-counting clamp at 1 severed the combining accent — the
		// exact split TS-TCP-023 forbids.
		{"combining mark stays with its base", "éx", 1, "é"},
		{"combining sequence counts as one unit", "éé", 2, "éé"},
		// 63 ASCII then a combining pair: the pair is character 64 and
		// survives whole; nothing after it does.
		{
			"limit lands after a full cluster",
			str63() + "éz", 64, str63() + "é",
		},
		// A ZWJ emoji sequence is one unit however many scalars it spans.
		{"zwj sequence is one unit", "\U0001F469‍\U0001F4BB" + "x", 1, "\U0001F469‍\U0001F4BB"},
	}
	for _, tc := range cases {
		if got := clamp(tc.in, tc.limit); got != tc.want {
			t.Errorf("%s: clamp(%q, %d) = %q, want %q", tc.name, tc.in, tc.limit, got, tc.want)
		}
	}
}

func str63() string {
	out := make([]byte, 63)
	for i := range out {
		out[i] = 'h'
	}
	return string(out)
}

func TestClampIsIdempotent(t *testing.T) {
	for _, s := range []string{"", "plain", "ééé", "\U0001F469‍\U0001F4BB"} {
		once := clamp(s, 2)
		if again := clamp(once, 2); again != once {
			t.Errorf("clamp is not a fixed point on %q: %q then %q", s, once, again)
		}
	}
}
