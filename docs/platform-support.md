---
title: Platform support
nav_order: 3
permalink: /platform-support/
---

# Platform support
{: .no_toc }

1. TOC
{:toc}

What works where. macOS is the reference implementation; Linux and Windows
are newer and deliberately incomplete in places. **Browser** is the fourth
column: a page, not an app — it only *views*, only as a guest (via the web
form of a share link), and every byte to it is relayed, since a browser
can't hole-punch. Mechanics: `plans/browser-viewer.md`.

This page also serves as the **alignment scoreboard** — every ⚠️ and ❌ is
either a gap worth closing or a decision worth writing down; the priority
order, and which gaps are deliberate divergences rather than debt, is in
`plans/platform-alignment.md`.

**Rows track `main`, not open pull requests.** ✅ means the thing works for
someone who installed the app — merged *and* consumed by the product, not
just the backend. A ⚠️ row's note says what the partial case *is*, because
that's the part a reader can act on.

## Legend

| | |
| :--- | :--- |
| ✅ | works |
| ⚠️ | partial — see the note |
| ❌ | not implemented |
| — | not applicable on this platform |

## The session

| | macOS | Linux | Windows | Browser |
| :--- | :---: | :---: | :---: | :---: |
| View a shared screen | ✅ | ✅ | ✅ | ✅ Chrome, Edge, Firefox; Safari untested |
| Share your screen | ✅ | ✅ | ✅ | — |
| Share a single window | ✅ | ✅ portal | ✅ | — |
| Share a single app / several apps | ✅ | ⚠️ single, via portal | ❌ | — |
| Change source mid-share | ✅ | ✅ | ✅ | — |
| Preview thumbnail of what you're sharing | ✅ | ✅ | ✅ | — |
| Capture backend | ScreenCaptureKit | X11 (`libxcb`) / ScreenCast portal | Windows.Graphics.Capture | — |
| Hardware encode | ✅ VideoToolbox | ❌ software libavcodec | ❌ software libavcodec | — |
| HEVC ⇄ H.264 negotiation | ✅ | ✅ | ✅ | ✅ asks for H.264 where HEVC can't decode |
| Wide gamut / 10-bit / HDR (sharing) | ✅ | ❌ | ❌ | — |
| Decode a 10-bit stream (viewing) | ✅ | ❌ | ❌ | ❌ |
| Share via Link (guests without a Tailscale account) | ✅ | ✅ | ✅ | — |
| Copy Link / Copy Web Link / Copy Token buttons | ✅ | ✅ | ✅ | — |
| Start a share without signing in (link-only) | ✅ | ✅ | ✅ | — |
| Join a share by link/token as a guest | ✅ | ✅ + `--join` CLI | ✅ | ✅ the only way in: the **web link** |
| Guests draw + request control (same capability gates as tailnet viewers) | ✅ | ✅ | ✅ | ✅ |
| `tailscreen:` link opens the app | ✅ | ✅ AppImage/Flatpak¹ | ✅ MSIX² | ⚠️ the web link opens the page; `tailscreen:` needs an app |

³ Browsers refuse to play audio until the page is clicked; **Enable Audio**
is that click. ⁴ **Join** in a browser means opening the **web link**
(`https://tailscreen.dev/view/#tc…`, from **Copy Web Link** on any app's
share card), or opening the page bare and pasting the link or bare token
into its join field — either way the token rides the URL fragment, so it
never reaches the server hosting the page. Everything the browser receives
is DERP-relayed — fine on a self-hosted relay, not the free ones at
screen-share bitrate.

¹ Link clicks reach the Linux app once a `.desktop` entry registers the
`tailscreen` scheme — the Flatpak exports one at install, an AppImage only
after desktop integration (e.g. AppImageLauncher, Gear Lever); a bare
binary or tarball registers nothing, so there the join card and
`tailscreen --join <link>` are the way in. ² On Windows the MSIX declares
the scheme, so the packaged install handles clicks; the zip build
registers nothing.

The two colour rows are independent — the viewing one is why a Mac
sharer's 10-bit toggle can quietly do nothing: viewers advertise 10-bit
decode support in `HELLO`, and a share holds itself at 8-bit while any
connected viewer can't decode it. libavcodec viewers can't yet, so a
Mac→Linux or Mac→Windows share stays 8-bit even with the toggle on —
correct colour, just not the extra two bits.

The Linux share card offers two doors: the primary button shares a screen;
a second — **"Share a window or app"**, present only with a desktop
portal — asks the portal for a window, drawing its own picker since the
compositor is what knows which windows exist and which this person may
see. The button is *absent*, not greyed, without a portal: sharing one
window is a capability an X11-only desktop genuinely lacks, and a window
selection is never silently widened to the whole screen.

**Wayland sharing works too.** The sharer picks its backend from the
session kind — `XDG_SESSION_TYPE`, never `$DISPLAY`, which XWayland also
sets on Wayland. X11 keeps direct root capture; Wayland negotiates the
ScreenCast portal (`PortalCaptureKit` + `TailscreenSharerPortal`, PipeWire
frames into the same BGRAToI420 → libavcodec seam as X11 and WGC),
starting with the compositor's consent dialog. A Wayland session with no
portal refuses rather than falling back to a capture that would only
appear to work. One honest limit: the annotation overlay and XTEST
injection are X11 machinery, so those extras work best there — Wayland
equivalents are future work.

## Audio

| | macOS | Linux | Windows | Browser |
| :--- | :---: | :---: | :---: | :---: |
| Hear the sharer's voice / other viewers | ✅ | ✅ | ✅ | ✅ after a click³ |
| Speak (microphone) | ✅ | ✅ | ✅ | ❌ |
| Share computer audio | ✅ | ❌ | ❌ | — |
| Playback backend | AVAudioEngine | ALSA | WASAPI | WebCodecs + Web Audio |
| Capture backend | VoiceProcessingIO | ALSA | WASAPI | — |

Voice runs both directions on every platform through one portable path
(`ThreadedMicrophone` + `BlockingPCMSource` over the shared Opus
encoder/decoder), ALSA and WASAPI capture behind the same seam. What
remains is **computer-audio capture**: macOS-only, since only
ScreenCaptureKit hands the capture pipeline the system's own output.
Viewers on every platform can still play it back.

## Interaction

| | macOS | Linux | Windows | Browser |
| :--- | :---: | :---: | :---: | :---: |
| Draw annotations as a viewer | ✅ | ✅ | ✅ | ✅ pen |
| Pick your annotation color | ✅ | ✅ | ✅ | ✅ |
| Render viewers' annotations as a sharer | ✅ | ✅ | ✅ | — |
| Draw on your own screen as a sharer | ✅ | ✅ | ✅ | — |
| Request remote control as a viewer | ✅ | ✅ | ✅ | ✅ |
| Visible "you are controlling" indicator | ✅ border + title | ✅ | ✅ | ✅ outline |
| Grant + inject remote control as a sharer | ✅ | ✅ | ✅ | — |
| Send a link for the sharer to open | ✅ | ✅ | ✅ | ✅ |
| Open a viewer's link as a sharer (after a click) | ✅ | ✅ | ✅ | — |
| Revoke hotkey / panic key | ✅ | ❌ | ❌ | — |
| Zoom + pan the viewer | ✅ | ✅ | ✅ | ❌ |
| Told why a session ended, with Reconnect | ✅ | ✅ | ✅ | ✅ |
| Detects a vanished sharer (timeout / dead socket) | ✅ | ✅ | ✅ | ⚠️ on connection close only |
| Cancel while waiting for approval | ✅ | ✅ | ✅ | ⚠️ close the tab |

Every row but the revoke hotkey is closed on all three platforms — mostly
wiring, since the protocol, grant gate, coordinate mapping and neutral key
model were already portable and tested; what was missing was the host
call, not a capability.

Three specifics worth knowing:

- **The Linux sharer's ✅ needs a composited session.** The overlay is an
  ARGB window; on uncomposited X11 there's no per-pixel alpha, so what
  should be transparent paints as opaque black — a black rectangle over
  the whole screen. It refuses to exist there, withholding the capability
  bit too, so viewers see disabled drawing tools rather than strokes
  reaching nobody. Every mainstream desktop composites; headless and
  bare-X setups don't.
- **The Linux sharer injects through XTEST, an optional X11 extension.**
  Without it, calls succeed but inject nothing, so presence is probed at
  open and the capability withheld when absent — viewers aren't offered
  Request Control rather than granted control whose clicks vanish. The
  headless sharer also defaults control off behind `--allow-control`: an
  unattended process shouldn't invite a peer to take the pointer just
  because it can.
- **Windows gates control and annotations on resolving the capture item's
  screen rect.** A WGC `GraphicsCaptureItem` carries no HMONITOR, so its
  size is matched against enumerated monitors; a *window* capture, or two
  identical monitors, declines rather than guesses — a click landing on a
  screen the viewer can't see is worse than no click, but it means both
  features can be correctly absent on a working share.

## Access control

| | macOS | Linux | Windows | Browser |
| :--- | :---: | :---: | :---: | :---: |
| Require approval for new viewers | ✅ | ✅ | ✅ | — |
| Remembered allow / "Deny & Block" | ✅ | ✅ | ✅ | — |
| Kick a connected viewer | ✅ | ✅ | ✅ | — |
| Ask a peer to share their screen | ✅ | ✅ | ✅ | — |

All of it is shared code: the approval gate, decision logic and the
StableNodeID-keyed intent queue live in the portable tier
(`ViewerRosterDecision` + `SharerAccessCoordinator`), and the hub renders
one viewer-row component on every host. (The server's own default is
approval *off* — right for a headless automation sharer; every app host
turns it on.)

Two things behind the ✅s are worth knowing: a remember decision can land a
moment after you make it — the store is keyed by Tailscale StableNodeID,
never a peer-supplied hostname, and that ID arrives from the sharer's own
netmap lookup a beat after the connection does, so a decision made before
then is queued rather than dropped, and the row says so instead of looking
unpressed. And being askable requires listening while idle — the part
actually missing for "Ask a peer to share": a request arrives exactly when
a machine is *not* sharing, so a listener that lives only as long as a
share answers nothing, indistinguishable to the asker from the peer being
away. Accepting also waives the approval gate for that peer — otherwise
the person you just invited hits your own gate and waits.

## The hub

| | macOS | Linux | Windows | Browser |
| :--- | :---: | :---: | :---: | :---: |
| Peer discovery + online status | ✅ | ✅ | ✅ | — |
| Multiple accounts | ✅ | ✅ | ✅ | — |
| Peer list filter (offline / sharing / tags) | ✅ | ✅ | ✅ | — |
| Peer detail: route, latency, ACL tags | ✅ | ✅ | ✅ | — |
| Quality settings UI | ✅ | ✅ | ✅ | ❌ |
| Connection stats overlay | ✅ | ✅ | ✅ | ✅ |
| Localized strings | ✅ | ✅ | ✅ | ⚠️ placards only |
| **Notified when a viewer is waiting for approval** | ✅ | ✅ | ⚠️ MSIX; the zip degrades | — |
| Answer that prompt from the notification | ✅ | ✅ | ⚠️ MSIX; the zip degrades | — |
| Told when notifications are switched off | ✅ | ✅ | ✅ | — |
| Notified when a viewer joins / leaves | ✅ | ✅ | ⚠️ MSIX; the zip degrades | — |
| **Outline around what's being captured** | ✅ | ⚠️ X11 display shares | ⚠️ WGC's own, unconfirmed | — |
| Sharing controls outside the main window | ✅ menubar | ❌ | ❌ | — |
| Mute / unmute from outside the window | ✅ | ✅ hotkey | ✅ hotkey | — |
| Toggle sharer drawing from outside the window | ✅ | ❌ | ❌ | — |
| Global hotkeys (mute, revoke control) | ✅ remappable | ⚠️ mute only | ⚠️ mute only | — |
| Told when a hotkey couldn't be registered | ✅ Settings | ✅ share card | ✅ share card | — |

Linux and Windows share their chrome (`Packages/TailscreenHubUI`) — the
most aligned block of the five — and their *strings*: one catalog
(`Packages/TailscreenL10n`) backs all three apps, so a string translated
for macOS is translated for the other two, and adding a language means
dropping one `<lang>.lproj` into that package (force one with
`TAILSCREEN_LANG=sv` to check your work). The peer-detail pane and the
share card's quality menu follow the same pattern: one component each
(`HubQualityMenu`), backed by the shared portable `QualitySettings` model.

The last block is about *where the sharing controls live*. On macOS the
live share's card — preview, mute, draw, approve a viewer, the link,
stop — renders in the window *and* the menubar item, so you can mute,
draw, approve a viewer or stop without the window ever coming forward.
Linux and Windows have the same card, but only in the window — which
during a share sits behind the thing you're sharing, so raising it is
itself visible to your viewers, and every mid-share action costs an
interruption the audience can see.

**Notifications are the most uneven block**, because approval defaults
*on*: a sharer not watching the window silently strands whoever tries to
connect. All three platforms post, and the *decisions* behind them — what
to say, when, when to take it back — are one shared, tested layer. Every
ask carries Accept/Deny answerable without leaving what you're doing; the
two that strand somebody mid-share break through Do Not Disturb (the
reports don't); nothing dings during a share, since a sound would go out
with your shared system audio. What differs is what each platform can
deliver:

- **macOS** breaks through Focus for the two mid-share asks, reads back
  whether notifications are off, and clears a banner once you answer in
  the app — needs the bundled app (`make run` output has no bundle id and
  posts nothing).
- **Linux** posts over `org.freedesktop.Notifications`. A daemon that
  can't render buttons is asked first; the wording then says where to
  answer instead, and the share card says so too — the same "degrades and
  says so" rule Windows' zip build follows.
- **Windows** posts through the Windows App SDK, but only when the app can
  register with the notification platform — today, the **MSIX**. The zip
  ships a self-contained runtime that omits the package those APIs need,
  so it degrades to in-window prompts and says so on the share card. The
  buttons are wired, but posting and observing a real Windows toast is the
  one part no CI can verify.

**"Am I still sharing?" is a different question, and an outline answers it
better than an icon** — a border around the captured region says not that
a share is running somewhere, but that *this* is what viewers can see.
macOS draws one for every share kind. Linux paints one under the
annotations overlay, but only for X11 display shares: the portal hands
back a stream size but no on-screen position, so a portal share gets no
indicator rather than a border around the wrong region. Windows didn't
need to build one — WGC draws its own capture border unless an app opts
out, and ours doesn't (unconfirmed on a real desktop).

What's left is the *surface*: a way to toggle drawing, and a revoke
hotkey, without raising the window over the thing being shared — the
capabilities behind them (microphone capture, the click-taking sharer
overlay) already exist everywhere. The mute hotkey shows the shape those
will take. swift-cross-ui offers nothing for any of this, so each needs a
platform shim; the plan is in
[`plans/sharer-surfaces.md`](https://github.com/middle-management/tailscreen/blob/main/plans/sharer-surfaces.md).

## Transport and resilience

Everything here is in the portable core and identical on all three
platforms, since none of it touches the OS (mechanics:
[Network Protocol]({{ site.baseurl }}{% link protocol.md %})):

NACK retransmission · XOR FEC · receiver reports · congestion control and
the fps ladder · adaptive bitrate · per-viewer fairness · reorder/jitter
buffering · keyframe request (PLI) · idle sweep · the codec fallback
ladder · the decode-failure escalation ladder (keyframe request → decoder
reset → a user-visible stall error).

Voice has its own resilience layer on the same terms — packet-loss
concealment, per-speaker jitter buffering, a cooldown on a failing
decoder, a sweep that retires quiet speakers — run identically on all
three platforms. Several people talking at once are summed into one
stream, so a sharer hearing two viewers, or a viewer hearing the sharer
and another viewer, hears them together rather than in alternating 20 ms
slices.

That's the point of the split: a bug fixed in loss recovery is fixed
everywhere, and platform code stays down to capture, encode, decode,
render, audio I/O and input injection.

## Diagnostics

Recording a session — handshakes, admission decisions, user actions,
active views, failures — and exporting it as a file you can send to
whoever is helping. Two sides' files merge into one ordered timeline, with
the clock difference between the machines solved from the handshake
itself. See
[Troubleshooting]({{ site.baseurl }}{% link troubleshooting.md %}#recording-diagnostics).

| | macOS | Linux | Windows | Browser |
| :--- | :---: | :---: | :---: | :---: |
| Record handshakes and admission decisions | ✅ | ✅ | ✅ | ❌ |
| Record media quality: first frame, decode failures and recovery, codec/bitrate/fps changes, a loss/RTT summary every 5 s | ✅ | ✅ | ✅ | ❌ |
| Record user actions, active views, surfaced failures | ✅ | ❌ | ❌ | ❌ |
| On by default in release candidates | ✅ | ✅ | ✅ | — |
| Settings toggle | ✅ | ⚠️ `TAILSCREEN_DIAGNOSTICS=1` / `=0` | ⚠️ `TAILSCREEN_DIAGNOSTICS=1` / `=0` | — |
| Export to a file | ✅ Settings → Diagnostics | ❌ | ❌ | — |
| Merge two recordings into one timeline | ✅ Settings → Diagnostics | ❌ | ❌ | — |

The **protocol half** is in the portable core, so all three platforms
record handshakes, admission decisions and log lines identically — the
half two bundles merge on, working between any pair of platforms.

The **app half** is macOS-only so far: which button was pressed, which
screen was in front of the user, and which failures were shown are
instrumented only in the macOS app. A Linux or Windows bundle explains
what the connection did but not what the person did, and there's no export
button on those platforms yet — both are follow-up work.

## Distribution

| | macOS | Linux | Windows | Browser |
| :--- | :---: | :---: | :---: | :---: |
| Architectures | universal (arm64 + x86_64) | x86_64, aarch64 | x64, arm64 | any (wasm) |
| Signed by a trusted authority | ✅ notarized | — | ❌ self-signed MSIX | — served over https |
| Package manager | Homebrew cask | ❌ (casks are macOS-only; Flatpak unpublished) | ❌ winget pending | — |
| Formats | `.app` zip | AppImage, tarball | zip, MSIX | hosted page, single-file HTML |

Windows signing is blocked on registering with SignPath's free OSS tier;
until then the MSIX installs only after its certificate is trusted — each
release ships the cert's public `.cer` beside it, and
[Install]({{ site.baseurl }}{% link install.md %}#installing-the-msix-trusting-the-certificate)
covers the one-time trust. The zip needs no trust step.
