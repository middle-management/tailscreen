# TailscreenHubUI

The hub's look, shared by every swift-cross-ui app in this repo — today the
Linux/GTK viewer (`Apps/linux-gtk`) and the Windows app (`Apps/windows`).

## Why this exists

macOS has a *hub*: a docked window whose title bar is hidden behind an empty
unified toolbar, with a thick header carrying the wordmark and a status
subtitle, a centered content column, rounded translucent cards, and a Screens
list of presence-dot + hostname + IP rows that expand into a detail pane.

swift-cross-ui is a SwiftUI **subset** — no SF Symbols, `Button` takes only a
`String` label, no `.buttonStyle` — so none of that comes for free. The GTK
viewer rebuilt it from primitives: `Circle` / `Capsule` / `RoundedRectangle`
fills, translucent-gray tints that read on both light and dark themes, and
`.onTapGesture` for the rows a `Button` cannot host.

Then the Windows app needed the same thing, and the choice was to do that work
a second time or to move it somewhere both apps can reach. A design system that
exists twice agrees on the day it is written and never again — so it lives here.

## What is in it

| Type | Role |
|---|---|
| `HubStyle` | The tokens: heights, radii, the translucent fills, the presence and sharing colors. |
| `.hubCard()` | The rounded, tinted, hairline-bordered card modifier. |
| `ViewerHeader` | Wordmark + subtitle, spinner, Refresh, account menu. Stands in for a title bar. |
| `HubScreen` | One row's worth of a discovered machine — including the sharing chip and caption derived from `TailscreenMetadata`. |
| `SharerRow` / `SharerDetail` | The list row and its inline detail pane. |
| `PickerContent` | The content column: login card → share card → Screens list (searchable) or status pane. |
| `HubStatusPane` / `HubLoginCard` | Centered spinner + status; the interactive-login placard. |
| `ShareCard` | The sharing half of the hub: start/stop, notes, prompts, and the per-share settings switches. |
| `SessionPlacard` / `HubSessionPhase` | Connecting / awaiting approval / declined / ended. |
| `AnnotationToolbar`, `StatsHUD`, `RemoteControlBar` | The over-video chrome. |
| `HubAction`, `HubPrompt`, `HubToggle` | The small value types the cards take actions and settings through. |

## Rules

- **No platform code.** SwiftCrossUI and `TailscreenProtocol` only. Not GTK, not
  WinUI, not a transport, not a decoder. This is also what lets Linux CI
  typecheck the whole thing on the Windows app's behalf.
- **No transport types.** `DiscoveredSharer` lives in `TailscreenViewerTsnet`,
  which pulls TailscaleKit and therefore a Go archive; a package that only draws
  rectangles must not need one to compile. Hosts map their own discovery results
  into `HubScreen`.
- **Derive shared meaning here, not at the call sites.** The sharing chip and
  caption are computed in `HubScreen.init(…metadata:)` precisely so two apps
  cannot end up disagreeing about what "sharing" looks like.
- **Prompts are one shape.** A viewer waiting to be admitted and a viewer asking
  for control are the same interaction — a sentence and two buttons — and both
  go through `HubPrompt`. These apps have one window and no menubar to fall back
  on, so a prompt that is not rendered here is one nobody can ever answer. The
  switch that decides whether anyone has to ask — "Require approval for new
  viewers" — has nowhere else to live either, which is why `ShareCard` takes
  `settings` as well: a card that renders the prompts but not the gate is a
  card where the gate can only be off.
- **Values in, closures out — never a `Binding`.** `HubToggle` carries a `Bool`
  and a setter rather than a `Binding` because this package must not know where
  a setting is stored, and because both hosts rebuild their `ShareCard` from a
  computed property on every model change — there is no view-local state for a
  caller to bind to. The card stitches the pair back into the `Binding`
  SwiftCrossUI's `Toggle` wants.

## Building

```bash
swift build --package-path Packages/TailscreenHubUI
```

Builds on Linux, macOS and Windows. The `linux-app` CI job builds it
transitively; so does the Windows job.
