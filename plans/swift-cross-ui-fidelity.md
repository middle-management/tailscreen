# Spike: how close can the GTK and WinUI hubs get to the macOS app?

> **Status: spike/analysis complete; recommendations partially adopted.**
> `.help(_:)` tooltips have landed in `TailscreenHubUI` (`HubOverlays.swift`,
> `HubNotice.swift`). The `ToggleButton` annotation-tool swap and the
> AppKitBackend reference harness are **not done**. Findings pinned to
> swift-cross-ui revision `199a85614e3b2346aa10736b12f969af14a1f1ea` (see
> `Apps/windows/Package.swift`) — re-check if that revision moves.

## Goal

Both non-mac apps should read as the same product as macOS, "as close as
possible while still feeling like it belongs in its environment." This spike
inventoried what swift-cross-ui can actually express so follow-up work argues
about design, not capability.

## Findings & key decisions

- **The framework covers structure well; gaps cluster in depth/motion.**
  Shapes, gradients, corner radius, tooltips, hover, arbitrary paths and
  native toggles work on both GTK and WinUI backends today. `shadow`,
  `buttonStyle`, `animation`/`transition`, `clipShape`, `blur`, and
  materials/vibrancy are missing on **both** backends (framework-level, not
  fixable per-app). This split is convenient: structure is what makes two
  apps read as one product, and depth/motion is exactly where a platform app
  *should* diverge anyway.
- **Per-backend asymmetries to design around:** WinUI has no `Alerts`,
  `Sheets`, `RevealFiles`, or forced color scheme; GTK has all of those but
  can't be forced to a color scheme (`canOverrideWindowColorScheme = false`,
  so `HubStyle` colors must work in both light/dark — hence the existing
  `Color(white: 0.5, opacity:…)` overlay approach). Neither backend has
  `.segmented` (AppKit-only), so `ToggleButton` is the cross-platform
  substitute for a segmented control.
- **Decided against porting the macOS app onto swift-cross-ui too**, despite
  AppKitBackend existing as a `FullAppBackend`: no menu-bar-extra scene exists
  (no `NSStatusItem`/`MenuBarExtra` equivalent), and the mac app's entire
  sharer surface is a menubar item — decisive on its own. Also: it would level
  macOS *down* to the shared subset rather than raising the other two apps up;
  the dependency is pinned to a git revision, an acceptable risk for two
  secondary platforms but not for the primary app (ScreenCaptureKit,
  VideoToolbox, Metal, TCC, `NSWindow`); and the actual cosmetic gaps (native
  toggles, tooltips, hover, matched spacing) are already available and simply
  unused, so no rewrite is needed to fix them.
- **`AppKitBackend` reference harness recommended as highest-leverage next
  step (still not built)**: rendering `TailscreenHubUI` against AppKitBackend
  on a Mac would turn "align more with mac" from a matter of taste into a
  side-by-side diff, and would separate backend-fidelity bugs from
  our-own-layout bugs.

## Open items / recommended approach (not yet done, ordered by value/risk)

1. Build the AppKitBackend reference harness (ships nothing; settles design
   questions; add it to the screenshot CI jobs for drift detection).
2. Replace the annotation toolbar's ASCII-bracket selection hack
   (`[✎]` vs ` ✎ `) with `ToggleButton` + a derived per-tool `Binding` — both
   backends render it as a real native toggle. Called out as the single
   biggest visual win available.
3. `.help(_:)` on every remaining unlabelled glyph control (some added since;
   audit for gaps).
4. Reconcile `HubCards`' "My screen" wording/shape with macOS's "Sharing your
   screen" card (needs a wording/shape decision first — it's shared code, so
   changes both non-mac apps at once).
5. `onHover` on screen rows, if it reads well under GTK.

Explicitly not chased: shadows, vibrancy, animation — unavailable in the
framework, and their absence already matches how native GTK/WinUI apps look.

## Where it lives / how to iterate

- Shared chrome: `Packages/TailscreenHubUI` (`HubStyle`, `HubCards`,
  `HubOverlays`).
- Both `Apps/linux` and `Apps/windows` support `--ui-preview` /
  `--ui-preview-video` (seeded fake sharers) and CI screenshot capture
  (`app-linux.yml` `shoot linux-hub.png --ui-preview`; Windows workflow's
  `screenshots` input) — use these to review fidelity changes as CI images
  rather than from memory of a screenshot, which is what prompted this spike.
- Not investigated: whether upstream would take a `shadow`/`buttonStyle`
  contribution; font-hierarchy matching between platforms; `Paths` perf for
  hand-drawn controls (moot unless recommendation 2 is rejected).
