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

This page doubles as the **alignment scoreboard**: every ⚠️ and ❌ below is
either a gap worth closing or a decision worth writing down. The order to
close them in — and which ones are deliberate divergences rather than debt —
is `plans/platform-alignment.md`.

**Rows track `main`, not open pull requests.** A row is ✅ only when the
thing works for somebody who installed the app — the code is merged *and*
the product consumes it, not merely the backend. And a ⚠️ row's note says
what the partial case *is*, because that is the part a reader can act on.

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
| Share a single window | ✅ | ✅ portal | ✅ |
| Share a single app / several apps | ✅ | ⚠️ single, via portal | ❌ |
| Change source mid-share | ✅ | ✅ | ✅ |
| Preview thumbnail of what you're sharing | ✅ | ✅ | ✅ |
| Capture backend | ScreenCaptureKit | X11 (`libxcb`) / ScreenCast portal | Windows.Graphics.Capture |
| Hardware encode | ✅ VideoToolbox | ❌ software libavcodec | ❌ software libavcodec |
| HEVC ⇄ H.264 negotiation | ✅ | ✅ | ✅ |
| Wide gamut / 10-bit / HDR (sharing) | ✅ | ❌ | ❌ |
| Decode a 10-bit stream (viewing) | ✅ | ❌ | ❌ |

The two colour rows are independent, and the viewing one is why a mac
sharer's 10-bit setting can quietly do nothing: viewers advertise whether
they can decode 10-bit in their `HELLO`, and a share holds itself at 8-bit
for everyone while any viewer that can't is watching. The libavcodec viewers
can't yet, so a mac→Linux or mac→Windows share is 8-bit even with the
sharer's toggle on — correct colour and correct pictures, just not the extra
two bits.

The Linux share card offers two doors: the primary button shares a screen,
and a second — **"Share a window or app"**, present only when a desktop
portal exists — asks the portal for a window instead. The portal draws its
own picker (the compositor is the thing that knows which windows exist and
which ones this person may see), and the button is *absent* rather than
greyed on portal-less setups, because sharing one window is a capability an
X11-only desktop genuinely lacks; a window selection is never silently
widened to the whole screen.

**Wayland sharing works too.** The sharer picks its backend from the
session kind — `XDG_SESSION_TYPE`, never `$DISPLAY`, which XWayland sets
on Wayland desktops too. An X11 session keeps direct
root capture; a Wayland session negotiates the ScreenCast portal
(`PortalCaptureKit` + `TailscreenSharerPortal`, PipeWire frames into the
same BGRAToI420 → libavcodec seam as X11 and WGC), which begins with the
compositor's consent dialog; a Wayland session with no portal refuses
rather than falling back to the capture that would appear to work. One
honest limit: the annotation overlay and XTEST injection are X11
machinery, so those extras are at their best on an X11 session — the
Wayland-native equivalents are future work.

## Audio

| | macOS | Linux | Windows |
| :--- | :---: | :---: | :---: |
| Hear the sharer's voice / other viewers | ✅ | ✅ | ✅ |
| Speak (microphone) | ✅ | ✅ | ✅ |
| Share computer audio | ✅ | ❌ | ❌ |
| Playback backend | AVAudioEngine | ALSA | WASAPI |
| Capture backend | VoiceProcessingIO | ALSA | WASAPI |

Voice now runs both directions on every platform: one portable voice path
(`ThreadedMicrophone` + `BlockingPCMSource` over the shared Opus
encoder/decoder), with ALSA and WASAPI capture behind the same seam. What
remains is **computer-audio capture** — the Share System Audio button is
macOS-only, because only ScreenCaptureKit hands the capture pipeline the
system's own output; viewers on every platform play it back.

## Interaction

| | macOS | Linux | Windows |
| :--- | :---: | :---: | :---: |
| Draw annotations as a viewer | ✅ | ✅ | ✅ |
| Pick your annotation color | ✅ | ✅ | ✅ |
| Render viewers' annotations as a sharer | ✅ | ✅ | ✅ |
| Draw on your own screen as a sharer | ✅ | ✅ | ✅ |
| Request remote control as a viewer | ✅ | ✅ | ✅ |
| Visible "you are controlling" indicator | ✅ border + title | ✅ | ✅ |
| Grant + inject remote control as a sharer | ✅ | ✅ | ✅ |
| Revoke hotkey / panic key | ✅ | ❌ | ❌ |
| Zoom + pan the viewer | ✅ | ✅ | ✅ |
| Told why a session ended, with Reconnect | ✅ | ✅ | ✅ |
| Detects a vanished sharer (timeout / dead socket) | ✅ | ✅ | ✅ |
| Cancel while waiting for approval | ✅ | ✅ | ✅ |

Every row except the revoke hotkey is closed on all three platforms.
Closing them was mostly wiring: the protocol, the grant gate, the
coordinate mapping and the neutral key model were all portable and already
tested, so what was missing each time was the host call rather than a
capability.

Three specifics worth knowing:

- **The Linux sharer's ✅ has a condition: the session must be composited.**
  The overlay is an ARGB window, and on uncomposited X11 there is no per-pixel
  alpha — what should be transparent paints as opaque black, so the "overlay"
  would be a black rectangle over the sharer's whole screen. It therefore
  refuses to exist there, and the capability bit is withheld with it, so
  viewers see disabled drawing tools rather than strokes reaching nobody. Every
  mainstream desktop composites; headless and bare-X setups don't. (The bit is
  always *derived* from something the host actually has, never defaulted on.)
- **The Linux sharer injects through XTEST, which is an optional X11
  extension.** Without it every call succeeds and injects nothing, so its
  presence is probed at open and the capability is withheld when absent —
  viewers aren't offered Request Control rather than being granted control
  whose clicks vanish. The headless sharer additionally defaults control off
  behind `--allow-control`: an unattended process shouldn't invite a peer to
  take the pointer merely because it can.
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
| Remembered allow / "Deny & Block" | ✅ | ✅ | ✅ |
| Kick a connected viewer | ✅ | ✅ | ✅ |
| Ask a peer to share their screen | ✅ | ✅ | ✅ |

All of it comes from shared code: the approval gate, the decision logic and
the StableNodeID-keyed intent queue live in the portable tier
(`ViewerRosterDecision` + `SharerAccessCoordinator`), and the hub renders
one viewer-row component on every host. (The server's own default is
approval *off* — right for a headless automation sharer; every app host
turns it on.)

Two things behind the ✅s are worth knowing:

- **A remember decision can land a moment after you make it.** The store is
  keyed by Tailscale StableNodeID — never a hostname, which the peer supplies
  and could therefore choose — and that ID arrives from the sharer's own netmap
  lookup a beat after the connection does. A decision made before then is
  queued rather than dropped, and the row says so instead of looking unpressed.
- **Being askable requires listening while idle**, which is the part that was
  actually missing for "Ask a peer to share". A request arrives exactly when a
  machine is *not* sharing, so a listener that lives only as long as a share
  answers nothing — and to the asker that is indistinguishable from the peer
  being away. Accepting also waives the approval gate for that peer, or the
  person you just invited arrives at your own gate and is asked to wait.

## The hub

| | macOS | Linux | Windows |
| :--- | :---: | :---: | :---: |
| Peer discovery + online status | ✅ | ✅ | ✅ |
| Multiple accounts | ✅ | ✅ | ✅ |
| Peer list filter (offline / sharing / tags) | ✅ | ✅ | ✅ |
| Peer detail: route, latency, ACL tags | ✅ | ✅ | ✅ |
| Quality settings UI | ✅ | ✅ | ✅ |
| Connection stats overlay | ✅ | ✅ | ✅ |
| Localized strings | ✅ | ✅ | ✅ |
| **Notified when a viewer is waiting for approval** | ✅ | ✅ | ⚠️ MSIX; the zip degrades |
| Answer that prompt from the notification | ✅ | ✅ | ⚠️ MSIX; the zip degrades |
| Told when notifications are switched off | ✅ | ✅ | ✅ |
| Notified when a viewer joins / leaves | ✅ | ✅ | ⚠️ MSIX; the zip degrades |
| **Outline around what's being captured** | ✅ | ⚠️ X11 display shares | ⚠️ WGC's own, unconfirmed |
| Sharing controls outside the main window | ✅ menubar | ❌ | ❌ |
| Mute / unmute from outside the window | ✅ | ✅ hotkey | ✅ hotkey |
| Toggle sharer drawing from outside the window | ✅ | ❌ | ❌ |
| Global hotkeys (mute, revoke control) | ✅ remappable | ⚠️ mute only | ⚠️ mute only |
| Told when a hotkey couldn't be registered | ✅ Settings | ✅ share card | ✅ share card |

Linux and Windows share their chrome (`Packages/TailscreenHubUI`), so hub work
lands on both at once — which is why that block is the most aligned of the five.
They now share their *strings* too: one catalog (`Packages/TailscreenL10n`)
backs all three apps, so a string translated for macOS is translated for the
other two, and adding a language is dropping one `<lang>.lproj` into that
package. Force one with `TAILSCREEN_LANG=sv` to check your work.
The peer-detail pane and the share card's quality menu are that principle in
action: one component each (`HubQualityMenu`), serving both hosts, backed by
the same portable `QualitySettings` model and `PeerRoute`/latency
classifications the macOS hub uses.

The last block is about *where the sharing controls live*. On macOS the window is
the **hub** (sign-in, accounts, peer list) and the menubar item is the **sharer
tool**, so you mute, draw, approve a viewer and stop without the window ever
coming forward. Linux and Windows put everything in one window — which during a
share is behind the thing you're sharing, and raising it is itself visible to
your viewers. Every mid-share action costs an interruption the audience can see.

**Notifications are the most uneven block.** They matter because approval
defaults *on*: a sharer who isn't watching the window silently strands
whoever tries to connect. All three platforms post, and the *decisions*
behind them — what to say, when, when to take it back — are one shared,
tested layer, so they can't drift apart. Every ask carries Accept / Deny you answer without
leaving what you're doing, the two that strand somebody mid-share break through
Do Not Disturb and the reports don't, and nothing dings while a share is
running, because a notification sound is played by another process and would go
out with your shared system audio. What differs is what each platform can
actually deliver:

- **macOS** breaks through Focus for the two mid-share asks, reads back whether
  you've turned notifications off, and takes a banner down again once you
  answer in the app — an Accept that could only be a no-op reads as a broken
  button rather than a stale one. Needs the bundled app: `make run` output has
  no bundle id, and posts nothing at all.
- **Linux** posts over `org.freedesktop.Notifications`. A daemon that can't
  render buttons is asked first, the wording changes to say where to answer
  instead, and the share card says so too — the same "degrades and says so"
  rule the Windows zip build follows.
- **Windows** posts the same set through the Windows App SDK — but only when
  the app can register with the notification platform, which today means the
  **MSIX**. The zip ships a self-contained runtime that deliberately omits the
  package those APIs need, so it degrades to in-window prompts and *says so on
  the share card* rather than going quiet. The buttons and the press that comes
  back are wired, and are the one part of this no CI anywhere can verify:
  nothing in the project posts a Windows toast that a machine then observes.

**"Am I still sharing?" is a different question, and an outline answers it
better than an icon.** A border drawn around the captured region says what a
status glyph can't: not that a share is running somewhere, but that *this* is
what viewers can see. macOS draws one for every share kind. Linux paints one
under the annotations overlay for X11 display shares only: the portal hands
back a stream size but no position on screen, so a portal share gets no
indicator rather than a border around the wrong region. Windows didn't have
to build one — WGC draws its own capture border unless an app opts out, and ours
doesn't (still unconfirmed on a real desktop).

The capabilities behind the remaining rows now exist everywhere — microphone
capture and the click-taking sharer overlay both landed — so what's left
really is the *surface*: a way to toggle drawing, and a revoke hotkey,
without raising the window over the thing being shared. The mute hotkey shows
the shape those will take.

swift-cross-ui offers nothing for any of this, so each surface needs a platform
shim. The plan — including why notifications come first, why a tray icon was
considered and dropped, and why the outline is nearly free on two of the three
platforms — is in
[`plans/sharer-surfaces.md`](https://github.com/middle-management/tailscreen/blob/main/plans/sharer-surfaces.md).

## Transport and resilience

Everything here is in the portable core and identical on all three platforms,
because none of it touches the OS (the mechanics are on the
[Network Protocol]({{ site.baseurl }}{% link protocol.md %}) page):

NACK retransmission · XOR FEC · receiver reports · congestion control and the
fps ladder · adaptive bitrate · per-viewer fairness · reorder/jitter buffering ·
keyframe request (PLI) · idle sweep · the codec fallback ladder · the
decode-failure escalation ladder (keyframe request → decoder reset → a
user-visible stall error).

Voice has its own resilience layer on the same terms — packet-loss
concealment, per-speaker jitter buffering, a cooldown on a failing decoder,
a sweep that retires quiet speakers — and all three platforms run the same
decisions.

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
[Install]({{ site.baseurl }}{% link install.md %}#installing-the-msix-trusting-the-certificate)
documents the one-time trust — while the zip needs no trust step at all.
