package soul

import (
	"encoding/json"
	"strings"
	"testing"
)

const testPersona = "You are Nareida, Boss's assistant."

// The core contract: system role disappears, block lands on the first user
// message, canary is present, and the original user text survives.
func TestInject_StripsSystemAndPrependsBlock(t *testing.T) {
	body := map[string]any{
		"model": "deepseek-v3",
		"messages": []any{
			map[string]any{"role": "system", "content": "You are Qoder, a coding assistant."},
			map[string]any{"role": "user", "content": "halo"},
		},
	}

	out, injected, canary := Inject(body)
	if !injected {
		t.Fatal("expected injection")
	}
	if len(canary) != 8 {
		t.Fatalf("canary should be 8 hex chars, got %q", canary)
	}

	msgs, _ := out["messages"].([]any)
	if len(msgs) != 1 {
		t.Fatalf("expected 1 message after strip, got %d", len(msgs))
	}
	m0 := msgs[0].(map[string]any)
	if m0["role"] != "user" {
		t.Fatalf("first message must be user, got %v", m0["role"])
	}
	content, _ := m0["content"].(string)
	if !strings.Contains(content, MarkerOpen) {
		t.Error("missing open marker")
	}
	if !strings.Contains(content, "[SOUL_ID: "+canary+"]") {
		t.Error("missing canary")
	}
	if !strings.Contains(content, "halo") {
		t.Error("original user text was lost")
	}
	// The upstream persona must not survive anywhere.
	for _, m := range msgs {
		mm := m.(map[string]any)
		if mm["role"] == "system" {
			t.Error("system role survived")
		}
	}
}

// Empty persona must be a no-op: never inject an empty override block.
func TestInject_NoSystemMeansNoOp(t *testing.T) {
	body := map[string]any{
		"messages": []any{
			map[string]any{"role": "user", "content": "x"},
		},
	}
	out, injected, canary := Inject(body)
	if injected {
		t.Error("should not inject without a system message")
	}
	if canary != "" {
		t.Error("canary should be empty")
	}
	msgs := out["messages"].([]any)
	if len(msgs) != 1 {
		t.Fatalf("messages changed: %d", len(msgs))
	}
}

// Anthropic-style array content must be preserved as an array, with the block
// inserted as the first text part.
func TestInject_ArrayContentShape(t *testing.T) {
	body := map[string]any{
		"messages": []any{
			map[string]any{"role": "system", "content": testPersona},
			map[string]any{"role": "user", "content": []any{
				map[string]any{"type": "text", "text": "halo"},
			}},
		},
	}

	out, injected, _ := Inject(body)
	if !injected {
		t.Fatal("expected injection")
	}
	msgs := out["messages"].([]any)
	content, ok := msgs[0].(map[string]any)["content"].([]any)
	if !ok {
		t.Fatal("array content shape was not preserved")
	}
	if len(content) != 2 {
		t.Fatalf("expected 2 blocks, got %d", len(content))
	}
	first := content[0].(map[string]any)
	if first["type"] != "text" {
		t.Error("first block should be text")
	}
	if !strings.Contains(first["text"].(string), MarkerOpen) {
		t.Error("block not first")
	}
}

// When there is no user message at all, the block becomes a new user message.
func TestInject_NoUserMessage(t *testing.T) {
	body := map[string]any{
		"messages": []any{
			map[string]any{"role": "system", "content": testPersona},
		},
	}
	out, injected, _ := Inject(body)
	if !injected {
		t.Fatal("expected injection")
	}
	msgs := out["messages"].([]any)
	if len(msgs) != 1 {
		t.Fatalf("expected 1 message, got %d", len(msgs))
	}
	if msgs[0].(map[string]any)["role"] != "user" {
		t.Error("injected message must be user role")
	}
}

// The caller's map must not be mutated (the original body is reused for
// logging and for the next fallback attempt).
func TestInject_DoesNotMutateInput(t *testing.T) {
	body := map[string]any{
		"messages": []any{
			map[string]any{"role": "system", "content": "persona"},
			map[string]any{"role": "user", "content": "hi"},
		},
	}
	before := len(body["messages"].([]any))
	_, _, _ = Inject(body)
	after := len(body["messages"].([]any))
	if before != after {
		t.Fatalf("input mutated: %d -> %d", before, after)
	}
}

// Canary must be stable for identical persona and change with it.
func TestID_StableAndDistinct(t *testing.T) {
	a := ID(testPersona)
	b := ID(testPersona)
	if a != b {
		t.Error("canary not deterministic")
	}
	if len(a) != 8 {
		t.Errorf("expected 8 chars, got %d", len(a))
	}
	if ID(testPersona+"!") == a {
		t.Error("different persona should give different canary")
	}
	if ID("") != "" {
		t.Error("empty persona must give empty canary")
	}
}

// Enabled must accept bool and string forms from connection JSON.
func TestEnabled(t *testing.T) {
	cases := []struct {
		name string
		psd  map[string]any
		want bool
	}{
		{"nil", nil, true},
		{"absent", map[string]any{}, true},
		{"true bool", map[string]any{"soulMode": true}, true},
		{"false bool", map[string]any{"soulMode": false}, false},
		{"true string", map[string]any{"soulMode": "true"}, true},
		{"false string", map[string]any{"soulMode": "false"}, false},
		{"off string", map[string]any{"soulMode": "off"}, false},
		{"null", map[string]any{"soulMode": nil}, true},
		{"unrelated key", map[string]any{"other": true}, true},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := Enabled(c.psd); got != c.want {
				t.Errorf("Enabled = %v, want %v", got, c.want)
			}
		})
	}
}

// Byte-level entry point: malformed JSON must pass through untouched.
func TestInjectJSON_MalformedPassthrough(t *testing.T) {
	bad := []byte(`{"messages": not-json`)
	out, injected, _ := InjectJSON(bad)
	if injected {
		t.Error("should not inject on malformed JSON")
	}
	if string(out) != string(bad) {
		t.Error("bytes changed on malformed input")
	}
}

func TestInjectJSON_HappyPath(t *testing.T) {
	raw := []byte(`{"model":"m","messages":[{"role":"system","content":"persona"},{"role":"user","content":"hi"}]}`)
	out, injected, canary := InjectJSON(raw)
	if !injected {
		t.Fatal("expected injection")
	}
	var decoded map[string]any
	if err := json.Unmarshal(out, &decoded); err != nil {
		t.Fatalf("output is not valid JSON: %v", err)
	}
	if canary == "" {
		t.Error("canary missing")
	}
	if !strings.Contains(string(out), MarkerOpen) {
		t.Error("marker missing in output bytes")
	}
}
