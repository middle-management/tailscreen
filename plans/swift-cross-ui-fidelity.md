# Spike: how close can the GTK and WinUI hubs get to the macOS app?

**Goal.** Both non-mac apps should read as the same product as the macOS app —
"as close as possible while still feeling like it belongs in its environment."
This spike establishes what swift-cross-ui can actually express, so the
follow-up work argues about design rather than about capability.

**Scope.** Findings are pinned to swift-cross-ui revision
`199a85614e3b2346aa10736b12f969af14a1f1ea`, which `Apps/linux` and
`Apps/windows` share by construction (see the note in `Apps/windows/Package.swift`).
Re-run the inventory if that revision moves — several of the gaps below are the
kind upstream closes.

## The headline

The framework is a bigger subset of SwiftUI than the current UI uses, and the
remaining gaps cluster in **depth and motion**, not in structure. Cards,
strokes, corner radii, gradients, tooltips, hover, arbitrary vector paths and
native toggles are all available on both shipping backends today. Shadows,
`buttonStyle`, animation and materials are available on none of them.

That shape of gap is convenient, because structure is what makes two apps look
like one product, and depth/motion is exactly where a Windows or Linux app
*should* diverge from a Mac one anyway.

## Available on BOTH shipping backends

Verified against each backend's declared `BackendFeatures` conformances and the
core module's public surface.

| Capability | Notes |
|---|---|
| Shapes | `Rectangle`, `RoundedRectangle`, `Circle`, `Capsule`, with `.fill(_:)` and `.stroke(_:style:)` |
| `Paths` | Arbitrary vector drawing — the escape hatch for anything shape-shaped |
| Gradients | `LinearGradient` **and** `RadialGradient` |
| `cornerRadius` | A real backend feature on both (WinUI composition geometry, GTK CSS) |
| `background(_:)` / `overlay(_:)` | Both take an arbitrary `View`, so borders are `overlay(RoundedRectangle(...).stroke(...))` |
| Typography | `font`, `fontWeight`, `fontDesign`, `bold`, `italic`, `lineLimit`, `multilineTextAlignment` |
| `foregroundColor`, `Color` | Plus `colorScheme` / `preferredColorScheme` |
| `Tooltips` | `.help(_:)` — currently unused anywhere in our UI |
| `Gestures` | `onTapGesture`, `onHover`, `onClick` |
| Layout | `ZStack`, `GeometryReader`, `Spacer`, `Divider`, `frame`, `padding`, `aspectRatio`, `fixedSize`, `layoutPriority` |
| Controls | `ToggleButton`, `ToggleSwitch`, `Checkbox`, `Slider`, `Picker`, `Menu`, `Table`, `ScrollView`, `List`, `ProgressView`, `TextEditor` |
| Native escape hatch | `WinUIElementRepresentable` / `GtkWidgetRepresentable` — we already use the former for `WinUIVideoView` |

## Missing everywhere (no backend, no feature flag)

- **`shadow`** — nothing in the framework, so no card elevation.
- **`buttonStyle`** — a `Button` cannot be restyled. This is the single biggest
  constraint: any custom-looking button has to be built from
  `ZStack` + shape + `onTapGesture`, which forfeits native focus ring, keyboard
  activation and accessibility. Usually the wrong trade.
- **`animation` / `transition`** — no motion primitives at all.
- **`clipShape`**, **`blur`**, materials/vibrancy.
- **`offset`, `scaleEffect`, `rotationEffect`, `zIndex`.**
- **`Label`** (icon + text) and **`Section`** — both trivially composable from
  `HStack` / `VStack`, so they're naming gaps rather than capability gaps.

## Per-backend asymmetries that will bite

| | WinUI | GTK |
|---|---|---|
| `Alerts` | ✗ | ✓ |
| `Sheets` | ✗ | ✓ |
| `RevealFiles` | ✗ | ✓ |
| Menus | `AttachedMenus` | `PopoverMenus` |
| Picker styles | `.menu`, `.radioGroup` | `.menu` only |
| Force window color scheme | ✓ | ✗ (`canOverrideWindowColorScheme = false`) |

Two consequences worth writing down now:

- **A segmented control is not available.** `.segmented` is implemented by
  `AppKitBackend` alone. The obvious "make the annotation tools a mac-style
  segmented control" move is off the table; `ToggleButton` is the substitute.
- **GTK cannot be forced to a color scheme**, so dark mode there follows the
  desktop and our own `HubStyle` colors must work against both. They are
  currently all `Color(white: 0.5, opacity: …)` overlays, which is the right
  instinct for exactly this reason.

## The unused lever: AppKitBackend is a `FullAppBackend`

swift-cross-ui ships a complete AppKit backend, and it implements every
feature. Two things follow:

1. **A reference harness is possible.** `TailscreenHubUI` could be built against
   `AppKitBackend` on a Mac and put beside the real SwiftUI app. That converts
   "align more with mac" from a matter of taste into a side-by-side diff, and it
   would settle arguments about spacing and hierarchy in minutes rather than
   over round trips of installed builds.
2. **It bounds the blame.** If the shared hub looks right under AppKit and wrong
   under GTK/WinUI, the fault is backend fidelity. If it looks wrong under
   AppKit too, the fault is our layout — and no amount of backend work fixes it.

This is the highest-leverage next step and it ships nothing to users.

## Why not move the macOS app onto swift-cross-ui too

The AppKit backend makes this a fair question — one UI codebase would align the
three apps by construction rather than by discipline. The answer is still no,
for four reasons, the first of which is on its own decisive.

**1. There is no menu-bar-extra scene.** The scene types are `Window`,
`WindowGroup`, `AlertScene` and `Commands`. `AppKitBackend+MenuBar.swift` builds
the *application* menu bar (App/File/Edit/View) — there is no `NSStatusItem`
anywhere in the framework, and no `MenuBarExtra` equivalent. The macOS app's
entire sharer surface is a menubar item: share status, start/stop, mic, system
audio, drawing. Porting would mean keeping a hand-written AppKit surface for the
half of the app that matters most, so the "one codebase" benefit evaporates
before anything else is considered.

**2. It would level down, not up.** The gap list above is what macOS would
*lose*: no `buttonStyle`, no `shadow`, no animation, no materials. The macOS app
is the design reference precisely because it looks the way we want; rebuilding
it on the subset would make it look like the ports rather than the reverse. The
goal is to raise two apps, not lower three.

**3. The reference implementation is the wrong thing to bet.** The dependency is
pinned to a git revision, not a release. That is an acceptable risk for two
secondary platforms and a poor one for the app that works, is most used, and
carries ScreenCaptureKit, VideoToolbox, Metal, TCC prompts and `NSWindow`
construction — all of which would need representables or native escapes anyway.

**4. The cosmetic problem does not need it.** Everything the ports are actually
missing — native toggles, tooltips, hover, matched spacing and wording — is
available today and unused. Spending a macOS rewrite to fix that would be
solving an unrelated problem.

**What is worth taking from the idea:** the harness above, plus the discipline
it enables. Add an AppKit-backend rendering of `TailscreenHubUI` to the
screenshot jobs, and drift between the shared hub and the macOS design becomes
mechanically visible instead of something a person notices two platforms later.
That is alignment-by-construction pressure without a rewrite, and it points the
convergence the right way: the shared code moves toward macOS.

## What our UI is leaving on the table

The shared chrome already does the structural work — `HubStyle` carries a
spacing/radius/color scale and `HubStyle`'s card helper draws
`RoundedRectangle().fill()` + `.stroke()`, which is the mac card shape. What is
unused:

- **`ToggleButton(label, isOn:)`** — the annotation tools currently signal
  selection by wrapping the glyph in ASCII brackets (`[✎]` vs ` ✎ `). Both
  backends render `ToggleButton` as a genuine native toggle (WinUI
  `ToggleButton`, GTK `GtkToggleButton`) with a real pressed state. Single-select
  needs a derived `Binding` per tool (`activeTool == .pen`), which is a few
  lines. This is the biggest single visual win available and it makes the
  control *more* native, not less.
- **`.help(_:)`** — zero tooltips anywhere. Six unlabelled glyphs is most of why
  the annotation bar reads as unfinished; the `▤` stats toggle was reported as a
  missing feature by someone looking straight at it (fixed separately in #226 by
  wording it).
- **`onHover`** — no hover affordance on any row or button.
- **`RadialGradient` / `LinearGradient`** — unused. Not obviously needed, but
  it's the only depth tool available given `shadow` is absent.

## Recommended approach

**Match structure, let chrome be native.** Concretely: same cards in the same
order with the same wording and the same spacing scale as macOS; native
toggles, native menus, native scrollbars, platform default fonts. Do not chase
shadows, vibrancy or animation — they are unavailable, and their absence is
consistent with how GTK and WinUI apps look anyway. An app that matches macOS's
*information design* and its own platform's *control design* is the target;
a pixel-copy of macOS on Windows would fail the "belongs in its environment"
half of the goal.

Ordered by value per unit of risk:

1. Build the **AppKitBackend reference harness** (nothing ships; settles design questions).
2. **`ToggleButton` for the annotation tools**, replacing the bracket hack.
3. **`.help(_:)` on every glyph control** in both apps.
4. Reconcile **`HubCards`' "My screen"** with macOS's "Sharing your screen"
   card — needs a decision on the target wording/shape first, since it is
   shared and changes both non-mac apps at once.
5. **`onHover`** on screen rows, if it reads well under GTK.

## How to iterate on this

`Apps/linux` and `Apps/windows` both have `--ui-preview` (and
`--ui-preview-video`) which seed the hub with fake sharers, and `app-linux.yml`
already captures PNGs from them (`shoot linux-hub.png --ui-preview`); the
Windows workflow has a `screenshots` input for the same purpose. So every
fidelity change can be reviewed as an image in CI rather than described in
prose or trusted to a manual install. Use it — the whole reason this spike
exists is that UI claims were being made from memory of a screenshot.

## Not investigated

- Whether upstream would take a `shadow` feature, or how hard `buttonStyle`
  would be to add. Both are plausible contributions rather than blockers.
- Font *matching* — whether GTK/WinUI default fonts at our sizes read as the
  same hierarchy macOS gets from the system font. Best answered with the
  reference harness in hand.
- Whether `Paths` is fast enough to hand-draw controls per frame. Irrelevant
  unless recommendation 2 is rejected.
