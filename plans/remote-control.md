# Opt-in Remote Control (viewer input injected on the sharer's machine)

> Status: shipped, on all three platforms. Current wire bytes, gate and
> injector behavior are documented in `.claude/rules/protocol.md` ("Remote
> control — TCP framed") — that's the authoritative reference; this doc
> keeps only the design rationale not restated there.

## Goal

Let a viewer drive the sharer's machine (mouse/keyboard) over the existing
framed TCP control channel, opt-in and single-grantee, injected via
`CGEvent` (macOS) / `SendInput` (Windows) / XTEST (Linux), with an
authoritative server-side gate and instant revoke.

## Key decisions and why

- **Keys carry USB HID usage IDs + a neutral 5-bit `KeyModifiers` set on the
  wire, never raw `CGKeyCode`/`CGEventFlags`.** Decided during the original
  macOS-only design already, ahead of porting — paid off directly when
  Linux/Windows injection landed with no wire change (see
  `plans/porting-plan.md`'s `InputEvent` rewrite).
- **Grant gate keys on `connectionID` alone, not viewer IP.** A TCP
  connection UUID is authoritative and unspoofable; a NAT rebind produces a
  fresh UUID, so a grant can never be silently inherited. Viewer IP /
  stable identity is still recorded for UI and revoke bookkeeping, but the
  hot-path gate (`RemoteControlPolicy.shouldInject`) needs only the UUID —
  no addr↔UUID map required to make the security property hold.
- **Injection lives in the main/long-lived process, not the capture
  helper.** `CGEvent` posting needs Accessibility TCC, a per-bundle grant
  the long-lived process is the natural holder of (the capture helper is
  respawned per share); injection has no `replayd` coupling, so the
  helper-isolation rationale for capture doesn't apply here. Same
  reasoning carried over to Linux (no helper subprocess at all) and
  Windows.
- **Control and drawing are mutually exclusive at the UI layer**, not
  simultaneously routable: entering control mode force-disables the
  annotation overlay's input, and losing the grant restores it. Avoids
  ambiguous double-interpretation of the same pointer stream.
- **No viewer→sharer "release" message in the first cut**; later added as
  `.controlReleased` (see the wire byte list in `.claude/rules/protocol.md`)
  once the plain revoke-on-disconnect/hotkey/menu set proved insufficient
  for a viewer to hand back control voluntarily mid-session.
- **Rate-limiting is two-sided**: viewer-side throttles `mouseMove` emission
  (reusing the existing annotation-drag throttle pattern); server-side
  coalesces to the latest move per drain tick and hard-caps event rate
  regardless of what a (potentially malicious) granted viewer sends — never
  trust the client for this.
- **Coordinate mapping is a pure function** (`RemoteControlMapping`) taking
  a normalized `[0,1]` point plus the live capture rect, kept separate from
  the side-effecting rect *resolver* (`CGWindowListCopyWindowInfo` on
  macOS) — this is what makes multi-display/window-drag geometry
  CI-testable with no display hardware. The window-share case re-resolves
  the rect per event and drops the input if the window is off-screen,
  rather than injecting against a stale rect.
- **Whole-machine keyboard scope, not confined to the shared window** — a
  deliberate choice, disclosed to the sharer at grant time, because
  per-app keyboard confinement has no reliable primitive on any of the
  three platforms (see the pointer-confinement discussion in
  `plans/porting-plan.md` for why the analogous *pointer* confinement
  problem is Wayland-specific and keyboard was never attempted at all).

## Rejected alternatives worth not re-proposing

- Routing input up through the UI state object for injection, rather than
  having the server/session own the injector directly — would have
  reordered events via UI-thread task scheduling instead of preserving
  order on the injector's own serial queue.
- Sharing the window-rect resolver between the drawing overlay and the
  injector by de-privatizing the overlay's copy — skipped because the
  overlay's version is `@MainActor`-isolated and the injector runs off
  that actor; a small duplicated nonisolated primitive was simpler than
  threading isolation through a shared one.

## Where it lives now

- Wire bytes, gate semantics, revoke triggers: `.claude/rules/protocol.md`.
- Pure decision logic: `RemoteControlPolicy`, `RemoteControlMapping`
  (TailscreenProtocol — portable, CI-tested with no display hardware).
- Per-platform injectors: `CGEvent`-based on macOS,
  `Packages/SendInputKit` on Windows, `Packages/XTestInjectKit` on Linux —
  each documented in the matching `.claude/rules/{macos-app,windows,linux}.md`.
- Prerequisite this built on: the viewer approval/allow-list machinery in
  `plans/viewer-consent-and-access-control.md`.
