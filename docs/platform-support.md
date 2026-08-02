---
title: Platform support
nav_order: 3
permalink: /platform-support/
---

# Platform support
{: .no_toc }

1. TOC
{:toc}

What works where. macOS is the reference implementation; Linux and Windows are
newer and deliberately incomplete in places.

This page doubles as the **alignment to-do**: every ⚠️ and ❌ below is either a
gap worth closing or a decision worth writing down, and several of them were
found by building this table rather than by anyone hitting them.

## Legend

| | |
| :--- | :--- |
| ✅ | works |
| ⚠️ | partial — see the note |
| ❌ | not implemented |
| — | not applicable on this platform |

## The session

| | macOS | Linux | Windows |
| :--- | :---: | :---: | :---: |
| View a shared screen | ✅ | ✅ | ✅ |
| Share your screen | ✅ | ✅ | ✅ |
| Share a single window | ✅ | ❌ | ✅ |
| Share a single app / several apps | ✅ | ❌ | ❌ |
| Change source mid-share | ✅ | ❌ | ❌ |
| Preview thumbnail of what you're sharing | ✅ | ❌ | ❌ |
| Capture backend | ScreenCaptureKit | X11 (`libxcb`) | Windows.Graphics.Capture |
| Hardware encode | ✅ VideoToolbox | ❌ software libavcodec | ❌ software libavcodec |
| HEVC ⇄ H.264 negotiation | ✅ | ✅ | ✅ |
| Wide gamut / 10-bit / HDR | ✅ | ❌ | ❌ |

The Linux sharer is display-only on purpose: window and app selections are
*refused* rather than silently widened to the whole screen. Wayland cannot be
shared from at all — the gate is `$DISPLAY`, and under XWayland capture sees
only the XWayland root, so native Wayland windows never reach viewers. The
ScreenCast portal is the answer and isn't written.

## Audio

| | macOS | Linux | Windows |
| :--- | :---: | :---: | :---: |
| Hear the sharer's voice / other viewers | ✅ | ✅ | ✅ |
| Speak (microphone) | ✅ | ❌ | ❌ |
| Share computer audio | ✅ | ❌ | ❌ |
| Playback backend | AVAudioEngine | ALSA | WASAPI |

Voice is the largest single gap. The Opus codec, framing, jitter buffer,
concealment and SSRC relay all live in the portable tier (`TailscreenAudio`,
`VoiceChannel`) and are unit-tested on Linux CI — what's missing on Linux and
Windows is only microphone **capture** and hooking it to the existing encoder.

## Interaction

| | macOS | Linux | Windows |
| :--- | :---: | :---: | :---: |
| Draw annotations as a viewer | ✅ | ✅ | ❌ |
| Render viewers' annotations as a sharer | ✅ | ⚠️ relays only | ✅ |
| Request remote control as a viewer | ✅ | ✅ | ❌ |
| Grant + inject remote control as a sharer | ✅ | ❌ | ✅ |
| Revoke hotkey / panic key | ✅ | ❌ | ❌ |
| Zoom + pan the viewer | ✅ | ✅ | ❌ |

**Linux and Windows are mirror images here**, which is an accident of the order
things were built rather than a design: Linux grew the viewer half first, Windows
the sharer half. Closing either direction is mostly wiring — the protocol, the
grant gate, the coordinate mapping and the neutral key model are all portable and
already tested.

Two specifics worth knowing:

- **The Linux sharer advertises annotation support it doesn't have.** It leaves
  `rendersAnnotations` at its default `true` while supplying no overlay, so a
  viewer shows its drawing tools, and strokes are relayed to *other* viewers but
  never appear on the Linux sharer's own screen. With one viewer — the common
  case — drawing silently does nothing. The capability bit exists precisely to
  prevent this; passing `false` is a one-line fix, rendering them is the real one.
- **Windows gates control and annotations on resolving the capture item's screen
  rect.** A WGC `GraphicsCaptureItem` carries no HMONITOR, so its size is matched
  against the enumerated monitors; a *window* capture, or two identical monitors,
  declines rather than guessing. That's deliberate — a click landing on a screen
  the viewer can't see is worse than no click — but it means both features can be
  correctly absent on a working share.

## Access control

| | macOS | Linux | Windows |
| :--- | :---: | :---: | :---: |
| Require approval for new viewers | ✅ | ✅ | ✅ |
| Remembered allow / "Deny & Block" | ✅ | ❌ | ❌ |
| Kick a connected viewer | ✅ | ❌ | ❌ |
| Ask a peer to share their screen | ✅ | ❌ | ❌ |

The approval gate itself is portable and every host asserts it (the server's own
default is *off*, which is right for a headless automation sharer and wrong for
anything with a person in front of it). What Linux and Windows lack is the
persistent per-peer policy store and the UI to drive it.

## The hub

| | macOS | Linux | Windows |
| :--- | :---: | :---: | :---: |
| Peer discovery + online status | ✅ | ✅ | ✅ |
| Multiple accounts | ✅ | ✅ | ✅ |
| Peer list filter (offline / sharing / tags) | ✅ | ✅ | ✅ |
| Peer detail: route, latency, ACL tags | ✅ | ❌ | ❌ |
| Quality settings UI | ✅ | ❌ | ❌ |
| Connection stats overlay | ✅ | ❌ | ❌ |
| Localized strings | ✅ | ❌ | ❌ |
| **Notified when a viewer is waiting for approval** | ⚠️ posted, easily suppressed | ❌ | ❌ |
| Answer that prompt from the notification | ❌ | ❌ | ❌ |
| **Outline around what's being captured** | ❌ | ❌ | ✅ system border |
| Sharing controls outside the main window | ✅ menubar | ❌ | ❌ |
| Mute / unmute from outside the window | ✅ | ❌ | ❌ |
| Toggle sharer drawing from outside the window | ✅ | ❌ | ❌ |
| Global hotkeys (mute, revoke control) | ✅ | ❌ | ❌ |

Linux and Windows share their chrome (`Packages/TailscreenHubUI`), so hub work
lands on both at once — which is why that block is the most aligned of the five.
Both consume `QualitySettings.default` with no UI to change it.

The last block is about *where the sharing controls live*. On macOS the window is
the **hub** (sign-in, accounts, peer list) and the menubar item is the **sharer
tool**, so you mute, draw, approve a viewer and stop without the window ever
coming forward. Linux and Windows put everything in one window — which during a
share is behind the thing you're sharing, and raising it is itself visible to
your viewers. Every mid-share action costs an interruption the audience can see.

**Notifications are the worst of these gaps.** Approval defaults *on*, so a
sharer who isn't watching the window silently strands whoever tries to connect;
there is nothing to poll for and no way to find out. Linux and Windows post
nothing at all. macOS posts, but weakly: every notification is left at
`interruptionLevel = .active`, so a Focus — including the one people run while
presenting — swallows it, and none of them carry *actions*, so at best you are
told and then you go to the app.

**"Am I still sharing?" is a different question, and an outline answers it
better than an icon.** A border drawn around the captured region says what a
status glyph can't: not that a share is running somewhere, but that *this* is
what viewers can see. Windows already has one and didn't have to build it — WGC
draws its own capture border unless an app opts out, and ours doesn't.

The remaining rows are gated on capabilities rather than on a surface: muting
needs microphone capture, toggling drawing needs a sharer-side overlay that can
take a click, and neither exists on Linux or Windows (see Audio and Interaction
above). No surface can expose what isn't there.

swift-cross-ui offers nothing for any of this, so each surface needs a platform
shim. The plan — including why notifications come first, why a tray icon was
considered and dropped, and why the outline is nearly free on two of the three
platforms — is in
[`plans/sharer-surfaces.md`](https://github.com/middle-management/tailscreen/blob/main/plans/sharer-surfaces.md).

## Transport and resilience

Everything here is in the portable core and identical on all three platforms,
because none of it touches the OS:

NACK retransmission · XOR FEC · receiver reports · congestion control and the
fps ladder · adaptive bitrate · per-viewer fairness · reorder/jitter buffering ·
keyframe request (PLI) · idle sweep · the codec fallback ladder.

That is the point of the split: a bug fixed in the loss-recovery path is fixed
everywhere, and the platform code stays down to capture, encode, decode, render,
audio I/O and input injection.

## Distribution

| | macOS | Linux | Windows |
| :--- | :---: | :---: | :---: |
| Architectures | universal (arm64 + x86_64) | x86_64, aarch64 | x64, arm64 |
| Signed by a trusted authority | ✅ notarized | — | ❌ self-signed MSIX |
| Package manager | Homebrew cask | ❌ (casks are macOS-only; Flatpak unpublished) | ❌ winget pending |
| Formats | `.app` zip | AppImage, tarball | zip, MSIX |

Windows signing is blocked on registering with SignPath's free OSS tier; until
then the MSIX installs only after its certificate is trusted — each release
ships the cert's public `.cer` beside it, and
[Install]({% link install.md %}#installing-the-msix-trusting-the-certificate)
documents the one-time trust — while the zip needs no trust step at all.
