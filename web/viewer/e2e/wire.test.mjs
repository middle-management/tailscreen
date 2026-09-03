// Checks on wire.js — the page's pure wire half — with no browser: the HID
// table's anchors (TS-RMT-022), the modifier bit field (TS-RMT-023), the
// modifier-key exclusion (TS-RMT-025), and the JSON shapes of §12.2 / §11
// against the spec's own examples. `node web/viewer/e2e/wire.test.mjs`.

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import path from "node:path";
import vm from "node:vm";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const sandbox = { globalThis: null, URL, crypto: { randomUUID: () => "6C84FB90-12C4-11E1-840D-7B25C5EE775A" } };
sandbox.globalThis = sandbox;
vm.runInNewContext(readFileSync(path.join(here, "..", "wire.js"), "utf8"), sandbox);
const W = sandbox.TailscreenWire;
const json = (v) => JSON.parse(JSON.stringify(v));

// HID anchors, straight from the USB HID usage tables (keyboard/keypad page).
for (const [code, usage] of Object.entries({
  KeyA: 4, KeyZ: 29, Digit1: 30, Digit9: 38, Digit0: 39, Enter: 40, Escape: 41, Backspace: 42,
  Tab: 43, Space: 44, F1: 58, F12: 69, F13: 104, F24: 115, ArrowRight: 79, ArrowUp: 82,
  Numpad1: 89, Numpad9: 97, Numpad0: 98, NumpadEnter: 88, IntlBackslash: 100,
})) assert.equal(W.HID[code], usage, code);

// Modifier keys never ride as key events; their state rides `modifiers`.
for (const code of ["ShiftLeft", "ControlRight", "AltLeft", "MetaRight", "CapsLock"])
  assert.equal(W.input.usage({ code }), null, code);
assert.equal(W.input.usage({ code: "KeyA" }), 4);
assert.equal(W.input.usage({ code: "NoSuchKey" }), null);

assert.equal(W.modifiers({ shiftKey: true }), 1);
assert.equal(W.modifiers({ ctrlKey: true, metaKey: true }), 2 | 8);
assert.equal(W.modifiers({ altKey: true, getModifierState: (k) => k === "CapsLock" }), 4 | 16);

// §12.2 shapes.
assert.deepEqual(json(W.input.mouseMove(0.5, 0.5)), { mouseMove: { x: 0.5, y: 0.5 } });
assert.deepEqual(json(W.input.mouseDown(0.5, 0.5, "left", 8)), { mouseDown: { x: 0.5, y: 0.5, button: "left", modifiers: 8 } });
assert.deepEqual(json(W.input.mouseUp(0.5, 0.5, "left", 8)), { mouseUp: { x: 0.5, y: 0.5, button: "left", modifiers: 8 } });
assert.deepEqual(json(W.input.scroll(0.5, 0.5, 0, -3, 0)), { scroll: { x: 0.5, y: 0.5, deltaX: 0, deltaY: -3, modifiers: 0 } });
assert.deepEqual(json(W.input.keyDown(4, 2)), { keyDown: { key: 4, modifiers: 2 } });
assert.deepEqual(json(W.input.keyUp(4, 2)), { keyUp: { key: 4, modifiers: 2 } });
assert.equal(W.input.button({ button: 0 }), "left");
assert.equal(W.input.button({ button: 1 }), "middle");
assert.equal(W.input.button({ button: 2 }), "right");
assert.equal(W.input.button({ button: 4 }), null);
assert.deepEqual(json(W.input.lines({ deltaMode: 1, deltaX: 0, deltaY: -3 })), [0, -3]);

// §11 shapes, the spec's example verbatim.
const add = W.annotation.add("pen", [[0.25, 0.5], [0.3, 0.55]], { r: 1.0, g: 0.1, b: 0.15, a: 1.0 }, 3.0);
assert.deepEqual(json(add), {
  type: "add",
  annotation: {
    id: "6C84FB90-12C4-11E1-840D-7B25C5EE775A",
    tool: "pen",
    points: [[0.25, 0.5], [0.3, 0.55]],
    color: { r: 1.0, g: 0.1, b: 0.15, a: 1.0 },
    width: 3.0,
  },
});
assert.deepEqual(json(W.annotation.undo("x")), { type: "undo", id: "x" });
assert.deepEqual(json(W.annotation.clearAll()), { type: "clearAll" });

// The stroke width unit (TS-ANN-005): points against a 1000-px short edge,
// the apps' default 3 — pinned against the conformance vector's own `add`
// so the page can never again send a fraction the sharers draw as a hairline.
const vectors = JSON.parse(readFileSync(path.join(here, "../../../conformance/vectors/json-payloads.json"), "utf8"));
const vecAdd = JSON.parse(vectors.cases.find((c) => c.id === "json/annotation-add-pen").in.json);
assert.deepEqual(
  json(W.annotation.add("pen", [[0.25, 0.5], [0.3, 0.55]], { r: 1, g: 0.1, b: 0.15, a: 1 }, undefined, vecAdd.annotation.id)),
  vecAdd,
  "the page's add must serialise exactly like the specification's example, default width included",
);
assert.equal(W.annotation.defaultWidth, 3);
assert.equal(W.annotation.strokePixels(3, 1000), 3, "3 points on the reference edge is 3 px");
assert.equal(W.annotation.strokePixels(3, 720), 2.16, "and scales with the short edge");
assert.equal(W.annotation.strokePixels(3, 100), 1, "floored at one pixel");
assert.equal(W.annotation.strokePixels(undefined, 1000), 3, "a missing width is the default");
{
  // Through the renderer: the lineWidth it sets is the scaled one.
  const seen = [];
  const ctx = new Proxy({}, { get: (_, k) => (k === "lineWidth" ? undefined : () => {}), set: (_, k, v) => (k === "lineWidth" && seen.push(v), true) });
  const store = new W.AnnotationStore();
  store.apply(W.annotation.add("pen", [[0, 0], [1, 1]], { r: 1, g: 1, b: 1, a: 1 }));
  store.render(ctx, 1920, 1080);
  assert.deepEqual(seen, [3.24], "a 3-point stroke on a 1080-px short edge is 3.24 px");
}

// The store: add, undo, clear, and unknown-is-discarded (TS-ANN-003).
const store = new W.AnnotationStore();
assert.ok(store.apply(add));
assert.equal(store.items.size, 1);
assert.ok(store.apply({ type: "add", annotation: { id: "z", tool: "laser", points: [] } }));
assert.equal(store.items.size, 1, "unknown tool discarded");
assert.ok(store.apply(W.annotation.undo(add.annotation.id)));
assert.equal(store.items.size, 0);
assert.ok(store.apply(add));
assert.ok(store.apply(W.annotation.clearAll()));
assert.equal(store.items.size, 0);
assert.equal(store.apply({ type: "bogus" }), false);

// The join field's parser — the same cases ShareLinkFormatTests pins for
// ShareLinkFormat.token(fromUserInput:), so the two sides cannot drift.
const tok = "tc" + "A".repeat(20);
assert.equal(W.isPlausibleToken(tok), true);
assert.equal(W.tokenFromInput(tok), tok, "bare token");
assert.equal(W.tokenFromInput(`  ${tok}\n`), tok, "whitespace trimmed");
assert.equal(W.tokenFromInput(`tailscreen://join?token=${tok}`), tok, "app link");
assert.equal(W.tokenFromInput(`tailscreen:join?token=${tok}`), tok, "app link, path form");
assert.equal(W.tokenFromInput(`https://tailscreen.dev/view/#${tok}`), tok, "web link");
assert.equal(W.tokenFromInput(`https://example.com/anything/#${tok}`), tok, "web link from any host");
assert.equal(W.tokenFromInput(`http://127.0.0.1:8080/index.html?token=${tok}`), tok, "query form");
for (const bad of [
  "", "   ", "tcshort", "tc" + "A".repeat(10) + "!", "xx" + "A".repeat(20),
  `ftp://example.com/?token=${tok}`, `mailto:${tok}`, `https://example.com/?ref=${tok}`, "https://example.com/#nottoken",
]) assert.equal(W.tokenFromInput(bad), null, JSON.stringify(bad));

console.log("wire.test: ok");
