---
title: Troubleshooting
nav_order: 9
permalink: /troubleshooting/
---

# Troubleshooting
{: .no_toc }

1. TOC
{:toc}

Ordered from boring permission stuff to interesting failure modes. The
walkthroughs name macOS surfaces (System Settings, Console.app), but the
connection-side failure modes and fixes are the same on Linux and Windows.

## "Permission Denied" when capturing screen

Screen Recording either hasn't been granted, or it was granted but
Tailscreen wasn't relaunched.

1. **System Settings → Privacy & Security → Screen Recording.**
2. Toggle **Tailscreen** on. (If you launched it from Terminal, toggle
   Terminal on instead — macOS attaches the permission to the launching
   process.)
3. **Quit Tailscreen completely and relaunch it.** macOS doesn't push a
   new permission to a running process.

## "Connection Failed"

Walk this checklist in order:

1. Open the Tailscale app on both machines and confirm each sees the
   other in its device list. If they're not both green, it's a Tailscale
   problem first.
2. Confirm the hostname or IP. Expanding the sharer's row in the
   viewer's **Screens** list shows its MagicDNS name and IP.
3. Check your tailnet ACLs allow TCP **and** UDP on port 7447 from viewer
   to sharer. The default "everything to everything" ACL works fine; if
   you've tightened it, double-check 7447 is still allowed.
4. Try `tailscale ping <viewer-hostname>` from the sharer. If that fails,
   so will Tailscreen — the issue is in the underlying Tailscale
   connection.

## Viewer stuck on the Connecting screen

If the connection succeeds but the window sits on "Connecting to
*name*…", you're most likely **waiting in the sharer's approval queue**.
"Require approval for new viewers" is on by default: the sharer's
menubar, hub window and a notification all show an Accept/Deny row, and
nothing happens until they click it. Ask them to look, or press the
placard's Cancel button to give up.

**"Connection Declined"** means the sharer denied you — or previously hit
"Deny & Block" on your machine, in which case every future attempt is
rejected automatically until they remove you under **Settings → Viewers
→ Remembered viewers**.

For scripted use (CI, kiosks, `test-local.sh`-style automation) with no
human to click Accept, launch the **sharer** with
`TAILSCREEN_OPEN_DOOR=1` to force the approval gate off. It's the "anyone
on the tailnet connects instantly" switch — automation only.

## Two local instances see no peers

The most common cause of an empty peer list when testing locally: both
instances share the same Tailscale state directory
(`~/Library/Application Support/Tailscreen/tailscale`), so they get the
same machine key and the tailnet treats them as one device. The
**Screens** list excludes the device it's running on, so each instance
sees nothing.
{: .note }

Fix: use `./test-local.sh` (sets `TAILSCREEN_INSTANCE` per child), or set
it manually:

```bash
TAILSCREEN_INSTANCE=1 Apps/macOS/.build/debug/Tailscreen
TAILSCREEN_INSTANCE=2 Apps/macOS/.build/debug/Tailscreen
```

Each instance gets its own state directory and hostname, and they see
each other.

## Stuck on a DERP relay

`tailscale status` shows `direct` or `relay "<region>"` for each peer. On
DERP, latency goes up and you can feel it.

DERP fallback happens when one or both ends can't establish a direct
WireGuard connection. Common causes: symmetric NAT (cellular, some
enterprise Wi-Fi), an aggressive firewall blocking the UDP hole-punch
probes, or VPN software intercepting traffic in a way that breaks
Tailscale's path discovery. Read Tailscale's
[troubleshooting docs](https://tailscale.com/kb/1023/troubleshooting) on
direct connections — that's the right place to fix it.

## Low FPS or stuttering on a direct connection

If `tailscale status` confirms `direct` and it's still bad:

- Run `iperf3` between the two machines and check actual end-to-end
  bandwidth — Wi-Fi delivers a fraction of its negotiated link rate.
- If bandwidth is bad: switch one or both ends to wired Ethernet, usually
  the biggest single improvement.
- If bandwidth is good and video is still bad: open Console.app, filter
  for `Tailscreen`, and look for VideoToolbox errors (encoder starvation
  or decoder backpressure).
- Disable Wi-Fi power saving on both ends.
- **Set a bandwidth limit** (Settings → Quality → Limit bandwidth). Left
  off, the rate is derived from what you're sharing — large,
  high-resolution content asks for a lot, deliberately generous because a
  link that can carry it should get the quality. On Wi-Fi that's often
  more than the path has, and since voice shares the same connection as
  video, a saturated link breaks up audio too. If a limit fixes it, the
  link was the constraint.

## "Connection degraded" badge in the viewer toolbar

The Stats button turning into "Connection degraded — click for stats"
means video decoding has failed repeatedly and the automatic recovery
ladder is already several rungs in: request a keyframe → recreate the
decoder session → show this badge → and finally a **"Video has
stalled"** banner if several seconds pass with no successful decode.

The badge is informational — recovery keeps running behind it, and one
good keyframe clears it. If it persists, click it: the stats overlay's
**PLIs sent**, **Dropped** and **FEC recovered** rows point to network
loss (see the DERP and Wi-Fi sections above), while **Decode errs**
climbing on a clean connection points to a decoder problem (reconnect,
check Console.app for VideoToolbox errors). At the stalled banner, its
**Reconnect** button is the reliable reset.

Linux and Windows run the same recovery ladder (it lives in the shared
core) with a simpler surface: no degraded badge, just the decoder reset
at the same rung, and a persistent stall shows the same **"Video has
stalled"** message as a dismissible strip over the last frame. If
decoding recovers, the strip clears on the next frame; if not, **Stop**
in the bar above returns you to the screen list to reconnect. (Exception
on Linux: a stall on a session that never showed a frame replaces the
placard instead, since there's no picture to keep and the placard carries
Reconnect.)

## Remote control grant fails asking for Accessibility

Granting control the first time pops **"Accessibility Permission
Needed"** — expected, since injecting mouse/keyboard events needs the
Accessibility permission, separate from Screen Recording. Open **System
Settings → Privacy & Security → Accessibility** and toggle Tailscreen on;
the grant you clicked is queued (the request's row says "Waiting for
Accessibility permission…") and completes on its own once the permission
lands, no second click needed. From Terminal, the permission may need to
go to Terminal instead, same as Screen Recording.

## "Microphone permission denied", and Tailscreen isn't in the Microphone list

**System Settings → Privacy & Security → Microphone** has no Tailscreen
row, so there's nothing to grant. Release builds up to **v0.10.0-rc.7**
lacked the entitlement macOS requires before it will even ask for the
microphone, so the request was denied on the spot and never shown. Fixed
in the next build — update rather than reinstall. If you'd also denied an
older prompt, clear the stale decision after updating:

```bash
tccutil reset Microphone se.middlemanagement.tailscreen
```

Sharing your screen and hearing others were never affected; only sending
your own voice was.

## The other side goes silent the moment you turn your microphone on

You could hear them, you turn your own mic on, and from that moment you
hear nothing — turning it off again doesn't help, and picture and your
own voice are unaffected. **v0.10.0-rc.14** and earlier on macOS did this
on both seats of a call: each machine stopped hearing the other the
instant its *own* mic came on. Fixed in the next build.

Cause: turning the mic on restarts the audio engine for echo
cancellation, and the restart threw away the other side's queued voice
without resetting the playback bookkeeping. The queued-audio count stayed
pinned at its limit, so every later packet was silently dropped as "too
much queued." That bookkeeping now resets on every engine restart (mic
toggle, output-device change, headset plugged in).

Workaround on an affected build: turn the mic on *before* connecting
(viewer) or before anyone joins (sharer), so the restart happens with
nothing queued — or use the mic on one seat only. On a build after
rc.14, if you still see this, run Tailscreen from a terminal: a healthy
restart logs `MicCapture: playback queues reset` followed by voice
resuming, and the once-a-minute `VoiceChannel: stats` line shouldn't show
`overruns=` climbing while nothing is heard. Include those lines and a
diagnostics recording from both seats in the report.

## Capture restarts by itself mid-share

Viewers see a brief pause; the sharer's log shows a helper restart. The
parent process watches the capture helper and restarts it after 15
seconds of silence — the hung-capture watchdog catching a wedged SCStream
that didn't exit. The restart *is* the fix.

A static screen doesn't trip this: the helper emits a ~1 Hz heartbeat off
ScreenCaptureKit's idle frames even with no pixel changes, so "nothing is
moving" and "capture is dead" stay distinguishable — you can share a
motionless dashboard for hours.

If the watchdog misfires, `TAILSCREEN_DISABLE_HELPER_WATCHDOG=1` is the
escape hatch — but file an issue, since a legitimate 15-second silence
from a live helper shouldn't exist.

## Black viewer window, no frames at all

**Toolbar visible, video area black.** The connection succeeded but no
keyframe has arrived (or the SPS/PPS for the current keyframe was lost).
Disconnect and reconnect to trigger a fresh keyframe. If it recurs, see
the Wi-Fi quality section above.

**Window entirely black, no toolbar.** Something failed during window
construction. Check Console.app for Metal or VideoToolbox errors, and
restart both apps first.

## Colours look washed out, or shadows look crushed

Open the viewer's stats overlay (macOS: **Stats** in the toolbar; Linux
and Windows: the **Stats** button) and read the colour line, e.g.
`BT.709 · limited` or `P3 · full` — what the sender said about the
stream.

The two ranges use the 0–255 byte differently: *limited* puts black at 16
and white at 235, *full* uses the whole byte. Decoding one as the other
greys out blacks or clips highlights. Viewers pick their maths from what
the stream says, so a mismatch means the sender is mislabelling its
video, not that the viewer guessed wrong — worth a bug report with the
colour line and both platforms named.

The macOS viewer's line shows colour primaries only (`P3`, `BT.2020 ·
PQ`, or `—` for a plain BT.709 stream), with no range shown because its
decoder hands the renderer RGB, by which point the stream's range is
gone.

## The share link won't mint, or a guest can't connect

Creating a link needs the network twice: once to fetch the DERP relay map
and once to hold the relay connection the token names. "Couldn't create
the link" almost always means one of those was unreachable — check the
sharer's connectivity (or, if you set a custom relay under **Settings →
Link sharing**, that override URL).

A guest stuck on the waiting placard usually isn't stuck: guest approval
is mandatory on every join, so nothing happens until the sharer presses
Accept — check their screen or notifications. If the guest fails outright
instead, in order: the link was **rotated or the share stopped** (each
link dies with its share — get a fresh one); the token was mangled in
transit (paste it again — the whole `tailscreen://join?token=…` line or
the bare `tc…` token both work); or the guest's network blocks the
outbound HTTPS/TLS connection the relay bootstrap needs.

## The browser viewer: a 404, a blank stage, or "codec unsupported"

The web form of a share link opens a page instead of an app
([Usage]({{ site.baseurl }}{% link usage.md %}#sharing-via-link-guests)),
and its failure modes are mostly the browser's:

- **`tailscreen.dev/view/` is a 404.** That root URL — the one the apps'
  **Copy Web Link** produces — only exists once a stable release ships
  it; until then the same page is served from
  `https://tailscreen.dev/next/view/`. Keep the `#tc…` fragment when
  changing the path — the token lives there — or open the page bare and
  paste the whole link into its join field.
- **"Waiting for approval" and nothing happens.** Same as any guest: the
  sharer has to press Accept, every join.
- **Stage stays blank, or "codec unsupported."** The page decodes with
  the browser's own decoders (WebCodecs), and H.264 is a *licensed*
  codec not every build carries — Chrome, Edge and Firefox have it;
  plain Chromium and some distro-packaged browsers don't. Try one of the
  three. An HEVC share isn't the problem — the page asks the sharer to
  fall back to H.264 on its own.
- **WebCodecs is "not defined."** Browsers expose it only in a *secure
  context*: `https://` or a file opened from disk. A copy served over
  plain `http://` from a LAN host won't decode; serve it over TLS, or use
  the single-file bundle (`make web-viewer-bundle`) from disk.
- **Video but no sound.** Browsers refuse to play audio until the page
  has been clicked; press **Enable Audio**. If still silent, the Stats
  overlay's audio line says where it stops, left to right. `rtp` counts
  every audio packet that arrived, before the page decides what to do
  with it. **`rtp 0` while the picture moves means nothing was sent**:
  sound and picture ride the same TCP connection in a browser, so there's
  no losing one and keeping the other. That points at the sharer: their
  microphone starts muted until unmuted, and Share System Audio is a
  separate switch. (Exception: a viewer far enough behind that the sharer
  sheds its audio to catch up, which thins the count rather than zeroing
  it.) Past that, `voice` and `system` split what was accepted by kind,
  `decoded` counts what the browser turned into sound, `MUTED` appears
  when this page's button is silencing it, and `ctx` is the browser's
  audio output: `running` is right, `suspended` means the browser is
  still blocking playback (click anywhere on the page; check the site's
  autoplay permission), and `unsupported` means this browser has no
  WebCodecs audio decoder.
- **It stutters more than the apps do.** A browser can't hole-punch, so
  everything crosses a DERP relay at screen-share bitrate for the whole
  session, and packet loss shows up as delay rather than dropped frames.
  Tailscale's free relays aren't sized for that; a
  [self-hosted relay]({{ site.baseurl }}{% link self-hosted.md %}#your-own-relay-for-share-links-derper)
  fixes it, and a native app on the same machine always does better.

The page's **Log** button shows what it saw — codec probes, the approval
sequence, decode errors — and is what to paste into a bug report.

## Clicking a tailscreen: link does nothing

The scheme is registered by the *packaged* app, and each platform has a
gap: macOS — only the released `.app` bundle registers, never a `make
run` dev binary. Linux — the Flatpak registers at install; an AppImage
only after desktop integration (AppImageLauncher or similar); a bare
binary or tarball never (use **Join a Share…** or
`tailscreen --join <link>` instead). Windows — the MSIX registers, the
zip build doesn't. Pasting the link into the join field always works
everywhere.

## The app is in English even though my system isn't

Tailscreen ships English and Swedish today; anything else falls back to
English, one string at a time, by design.

If a shipped language still shows English, the string catalog probably
isn't beside the binary. It travels as a `…_TailscreenL10n.bundle`
directory — inside `Tailscreen.app/Contents/Resources/` on macOS, next to
`tailscreen` / `tailscreen.exe` on Linux and Windows. Copying just the
executable out of a tarball or zip leaves it behind, and the app renders
in English without complaining.

To check which language is picked, or preview another without changing
system settings:

```bash
TAILSCREEN_LANG=sv ./tailscreen
```

On Linux the language otherwise comes from `LC_ALL` / `LC_MESSAGES` /
`LANG`, on Windows from the user's default UI language, and on macOS from
the ordered list in System Settings → General → Language & Region.

## Build fails with linker errors

You ran bare `swift build` without going through `make` first, so the Go
toolchain hasn't built `libtailscale.a` — there's nothing to link
against. Run `make build` (or at minimum `make tailscale`) once; after
that `swift build` works for the rest of the build tree.

## TailscaleKit submodule looks empty

You cloned without `--recurse-submodules`. Fix:

```bash
git submodule update --init --recursive
```

`Packages/TailscaleKit/upstream/libtailscale` is pinned in `.gitmodules`
and required for the build.

## Recording diagnostics

Tailscreen can record what happened during a session — connections,
handshakes, the actions you took, anything that failed, and how the
picture was doing (first-frame timing, decode trouble and recovery
steps, codec/rate changes, and a packet-loss/retransmit/FEC/RTT summary
every five seconds from both ends) — and write it to a file you can send
to whoever is helping you.

**In a release candidate this is on by default** — a candidate exists to
be tested, and an unexplainable problem is worth little. In a stable
release it's off until you turn it on under **Settings → Diagnostics**.
Your choice sticks across upgrades.

### Getting a recording out

1. **macOS: Settings → Diagnostics → Export Diagnostics…** The file lands
   in `~/Library/Logs/Tailscreen/` and Finder opens on it. You can export
   whether or not recording is still on — "reproduce it, stop, export"
   works.
2. **Linux and Windows have no export button yet.** Those apps record,
   and `TAILSCREEN_DIAGNOSTICS=1` / `=0` switches it, but getting the
   file out is still to come — see
   [Platform support]({{ site.baseurl }}{% link platform-support.md %}#diagnostics).
   Until then, send a macOS bundle from one end plus the other end's
   console output.
3. **Get one from both ends where you can.** This is what matters: one
   side's file says what your machine did, the pair says what
   *happened*. A viewer that waited thirty seconds and gave up looks
   identical whether the sharer never saw the connection or saw it and
   parked it on an approval prompt nobody was watching — only the two
   files together tell those apart.
4. **On macOS, read the pair yourself: Settings → Diagnostics → Merge
   With…** Pick the file the other end sent you and it's combined with
   this Mac's own recording into one ordered timeline, written beside the
   exports as `tailscreen-merged-….txt`. The two machines' clocks don't
   need to agree — the offset is worked out from the handshake the two
   sides already share, and the result says which clock it used and how
   far off the other one was. More than two ends (a sharer with two
   viewers) can be picked at once.
5. Attach what you have to the issue.

Each file is named for the machine it came from
(`tailscreen-app-roberts-macbook-pro-20260917-100402.jsonl`), so a pair
stays straight in a chat thread.

### Merging two recordings

```
make merge-diagnostics FILES="tailscreen-app-their-mac-….jsonl tailscreen-app-your-pc-….jsonl"
```

Prints the merged timeline on stdout, so redirect it to keep it. Order
doesn't matter, a single file is allowed (renders that bundle alone), and
**the two machines' clocks don't need to agree** — the offset is solved
from the shared handshake, and the result says which clock it used as
reference and how far off the other was.

This needs a checkout of the repository and a Swift toolchain, so in
practice it's run by whoever is *helping* rather than the person
reporting the problem — send the files and let the other end merge them.
Nothing else is needed: the tool depends only on the Foundation-only
core, so there's no Go, libtailscale or libopus to build first.

Bundles from unrelated sessions still merge, but nothing pairs them, so
the timeline says so under **Clock alignment** rather than interleaving
two unrelated stories as one.

### What's in the file

It's text, one event per line, readable before you send it.

It **does** name your device and the devices it connected to, including
tailnet addresses — that's what lines the two files up, and without it
nobody can tell which viewer went black. It also names the microphones
and speakers attached to your machine and which was selected: "they
couldn't hear me" is usually either the wrong device picked or the right
one never showing up, and those are different problems.

It **does not** contain screen contents, audio, keystrokes, share links,
auth keys or sign-in URLs. Share links and keys are reduced to a short
fingerprint before anything is written — anyone holding one can join your
share, so they never reach the file even if some component logs one by
accident.

Every file states this in its own first line, so a forwarded copy still
carries the notice.

## Reporting a bug

If none of the above is your problem, file an issue at
[github.com/middle-management/tailscreen/issues](https://github.com/middle-management/tailscreen/issues).
Include:

- **Diagnostics recordings from both ends** (above) — the single most
  useful attachment, and on a release candidate you already have them.
- OS and version on both ends (`sw_vers` on macOS, your distro, or the
  Windows build), and the machine models.
- Tailscale version on both peers, and whether the connection is `direct`
  or via DERP (`tailscale status`).
- Relevant log lines — Console.app filtered for `Tailscreen` on macOS,
  stderr on Linux and Windows.

"It doesn't work" is hard to fix. The above is much easier.
</content>
