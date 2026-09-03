// The pure half of what the page puts on the framed channel — kept apart
// from viewer.js so it can be checked without a browser: the USB HID key
// map behind TS-RMT-022, the modifier bit field (TS-RMT-023), the input
// event and annotation JSON shapes of spec §10.2 / §11 / §12.2, and the
// small store that renders received annotations. No DOM in here except
// the `KeyboardEvent.code` names as string keys.

"use strict";

(function (root) {
  // W3C `KeyboardEvent.code` → USB HID keyboard/keypad page (0x07) usage.
  // Modifier keys are deliberately absent: their state rides `modifiers`
  // on every event and they are never sent standalone (TS-RMT-025).
  const HID = {
    Enter: 40, Escape: 41, Backspace: 42, Tab: 43, Space: 44, Minus: 45, Equal: 46,
    BracketLeft: 47, BracketRight: 48, Backslash: 49, IntlHash: 50, Semicolon: 51, Quote: 52,
    Backquote: 53, Comma: 54, Period: 55, Slash: 56,
    PrintScreen: 70, ScrollLock: 71, Pause: 72, Insert: 73, Home: 74, PageUp: 75, Delete: 76,
    End: 77, PageDown: 78, ArrowRight: 79, ArrowLeft: 80, ArrowDown: 81, ArrowUp: 82,
    NumLock: 83, NumpadDivide: 84, NumpadMultiply: 85, NumpadSubtract: 86, NumpadAdd: 87,
    NumpadEnter: 88, Numpad0: 98, NumpadDecimal: 99, IntlBackslash: 100, ContextMenu: 101,
  };
  for (let i = 0; i < 26; i++) HID["Key" + String.fromCharCode(65 + i)] = 4 + i;
  for (let i = 1; i <= 9; i++) HID["Digit" + i] = 29 + i;
  HID.Digit0 = 39;
  for (let i = 1; i <= 12; i++) HID["F" + i] = 57 + i;
  for (let i = 13; i <= 24; i++) HID["F" + i] = 91 + i;
  for (let i = 1; i <= 9; i++) HID["Numpad" + i] = 88 + i;

  const MODIFIER_CODES = new Set([
    "ShiftLeft", "ShiftRight", "ControlLeft", "ControlRight", "AltLeft", "AltRight",
    "MetaLeft", "MetaRight", "OSLeft", "OSRight", "CapsLock",
  ]);

  // TS-RMT-023: bit 0 shift, 1 control, 2 alt/option, 3 meta/command/super, 4 caps lock.
  function modifiers(e) {
    let m = 0;
    if (e.shiftKey) m |= 1;
    if (e.ctrlKey) m |= 2;
    if (e.altKey) m |= 4;
    if (e.metaKey) m |= 8;
    if (typeof e.getModifierState === "function" && e.getModifierState("CapsLock")) m |= 16;
    return m;
  }

  const BUTTONS = ["left", "middle", "right"]; // MouseEvent.button 0/1/2 (TS-RMT-021)

  const input = {
    mouseMove: (x, y) => ({ mouseMove: { x, y } }),
    mouseDown: (x, y, button, mods) => ({ mouseDown: { x, y, button, modifiers: mods } }),
    mouseUp: (x, y, button, mods) => ({ mouseUp: { x, y, button, modifiers: mods } }),
    scroll: (x, y, deltaX, deltaY, mods) => ({ scroll: { x, y, deltaX, deltaY, modifiers: mods } }),
    keyDown: (key, mods) => ({ keyDown: { key, modifiers: mods } }),
    keyUp: (key, mods) => ({ keyUp: { key, modifiers: mods } }),
    /** HID usage for a KeyboardEvent, or null when it must not be sent. */
    usage: (e) => (MODIFIER_CODES.has(e.code) ? null : (HID[e.code] ?? null)),
    button: (e) => BUTTONS[e.button] ?? null,
    /** Wheel deltas in line units (TS-RMT-028), whatever the browser reported in. */
    lines: (e) => {
      const k = e.deltaMode === 1 ? 1 : e.deltaMode === 2 ? 20 : 1 / 33;
      return [e.deltaX * k, e.deltaY * k];
    },
    modifiers,
  };

  // A stroke's `width` is in POINTS relative to the video's short edge, quoted
  // against a 1000-px reference (TS-ANN-005; `Annotation.defaultWidth` and
  // `AnnotationRasterizer.referenceShortEdge` on the Swift side): 3 means a
  // 3-px stroke on a 1000-px-tall frame, scaling with the display. It is NOT
  // a fraction of the frame — the page once sent 0.004 (≈3 px of its own
  // canvas), which the sharers drew as a 0.004-point hairline nobody could
  // see, while an app's 3.0 would have rendered here 2000 px wide.
  const DEFAULT_WIDTH = 3;
  const REFERENCE_SHORT_EDGE = 1000;
  const strokePixels = (width, short) => Math.max(1, ((width ?? DEFAULT_WIDTH) * short) / REFERENCE_SHORT_EDGE);

  const annotation = {
    add: (tool, points, color, width = DEFAULT_WIDTH, id = crypto.randomUUID()) => ({
      type: "add",
      annotation: { id, tool, points, color, width },
    }),
    undo: (id) => ({ type: "undo", id }),
    clearAll: () => ({ type: "clearAll" }),
    defaultWidth: DEFAULT_WIDTH,
    referenceShortEdge: REFERENCE_SHORT_EDGE,
    strokePixels,
  };

  const TOOLS = new Set(["pen", "line", "arrow", "rectangle", "oval", "click"]);

  // The viewer's copy of the shared canvas: what to draw, in arrival order.
  class AnnotationStore {
    constructor() {
      this.items = new Map(); // id → annotation, insertion-ordered
    }
    apply(op) {
      switch (op?.type) {
        case "add":
          if (op.annotation && TOOLS.has(op.annotation.tool) && Array.isArray(op.annotation.points)) {
            this.items.delete(op.annotation.id);
            this.items.set(op.annotation.id, op.annotation);
          }
          return true;
        case "undo":
          this.items.delete(op.id);
          return true;
        case "clearAll":
          this.items.clear();
          return true;
        default:
          return false; // TS-ANN-003: unknown is discarded, never fatal
      }
    }
    render(ctx, w, h) {
      ctx.clearRect(0, 0, w, h);
      const short = Math.min(w, h);
      for (const a of this.items.values()) drawAnnotation(ctx, a, w, h, short);
    }
  }

  function css(color) {
    const c = color ?? { r: 1, g: 0.2, b: 0.2, a: 1 };
    return `rgba(${Math.round(c.r * 255)},${Math.round(c.g * 255)},${Math.round(c.b * 255)},${c.a ?? 1})`;
  }

  function drawAnnotation(ctx, a, w, h, short) {
    const pts = a.points.map(([x, y]) => [x * w, y * h]);
    if (!pts.length) return;
    ctx.save();
    ctx.strokeStyle = ctx.fillStyle = css(a.color);
    ctx.lineWidth = strokePixels(a.width, short);
    ctx.lineCap = ctx.lineJoin = "round";
    const [x0, y0] = pts[0];
    const [x1, y1] = pts[pts.length - 1];
    switch (a.tool) {
      case "pen":
        ctx.beginPath();
        ctx.moveTo(x0, y0);
        for (const [x, y] of pts.slice(1)) ctx.lineTo(x, y);
        ctx.stroke();
        break;
      case "line":
      case "arrow": {
        ctx.beginPath();
        ctx.moveTo(x0, y0);
        ctx.lineTo(x1, y1);
        ctx.stroke();
        if (a.tool === "arrow") {
          // Same shape as AnnotationGeometry: head = max(12, 4×width) at ±150°.
          const len = Math.max(12, ctx.lineWidth * 4);
          const ang = Math.atan2(y1 - y0, x1 - x0);
          for (const d of [Math.PI * (150 / 180), -Math.PI * (150 / 180)]) {
            ctx.beginPath();
            ctx.moveTo(x1, y1);
            ctx.lineTo(x1 + len * Math.cos(ang + d), y1 + len * Math.sin(ang + d));
            ctx.stroke();
          }
        }
        break;
      }
      case "rectangle":
        ctx.strokeRect(Math.min(x0, x1), Math.min(y0, y1), Math.abs(x1 - x0), Math.abs(y1 - y0));
        break;
      case "oval":
        ctx.beginPath();
        ctx.ellipse((x0 + x1) / 2, (y0 + y1) / 2, Math.abs(x1 - x0) / 2, Math.abs(y1 - y0) / 2, 0, 0, Math.PI * 2);
        ctx.stroke();
        break;
      case "click":
        ctx.beginPath();
        ctx.arc(x0, y0, Math.max(8, ctx.lineWidth * 3), 0, Math.PI * 2);
        ctx.stroke();
        break;
    }
    ctx.restore();
  }

  // --- the join field's parser -------------------------------------------------
  //
  // The same rules as ShareLinkFormat.token(fromUserInput:) in the apps —
  // change both or neither (ShareLinkFormatTests and e2e/wire.test.mjs pin
  // the same cases). A token is "tc" + base64url, checked shallowly; the
  // guest node's decode is the real validation. Accepted wrappers: the
  // apps' `tailscreen://join?token=…` (and `tailscreen:join?token=…`), and
  // a web link from ANY host — the page is static and self-hostable, so the
  // host proves nothing; the fragment (or a `token` query item) is what a
  // join needs.
  const TOKEN_BODY = /^[A-Za-z0-9_-]+$/;
  function isPlausibleToken(s) {
    return typeof s === "string" && s.length > 10 && s.startsWith("tc") && TOKEN_BODY.test(s.slice(2));
  }
  function tokenFromInput(text) {
    const trimmed = String(text ?? "").trim();
    if (!trimmed) return null;
    if (isPlausibleToken(trimmed)) return trimmed;
    let url;
    try {
      url = new URL(trimmed);
    } catch {
      return null;
    }
    const query = url.searchParams.get("token");
    switch (url.protocol) {
      case "tailscreen:":
        return isPlausibleToken(query) ? query : null;
      case "https:":
      case "http:": {
        const fragment = url.hash.replace(/^#/, "");
        if (isPlausibleToken(fragment)) return fragment;
        return isPlausibleToken(query) ? query : null;
      }
      default:
        return null;
    }
  }

  root.TailscreenWire = { HID, input, annotation, AnnotationStore, modifiers, isPlausibleToken, tokenFromInput };
})(typeof window !== "undefined" ? window : globalThis);
