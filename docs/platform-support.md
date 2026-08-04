---
title: Platform support
nav_order: 3
permalink: /platform-support/
---

# Platform support
{: .no_toc }

1. TOC
{:toc}

Tailscreen has native apps for **macOS**, **Linux**, and **Windows**, and they
all speak the same protocol — any platform can view a share from, or share to,
any other. macOS is the reference implementation and still has a few features
the other platforms don't; the tables below show exactly what works where.

## Legend

| | |
| :--- | :--- |
| ✅ | works |
| ⚠️ | partial — see the note |
| ❌ | not yet available |
| — | not applicable |

## Sharing and viewing

| | macOS | Linux | Windows |
| :--- | :---: | :---: | :---: |
| View a shared screen | ✅ | ✅ | ✅ |
| Share a whole screen | ✅ | ✅ | ✅ |
| Share a single window | ✅ | ✅ ¹ | ✅ |
| Share one app / several apps | ✅ | ⚠️ ¹ | ❌ |
| Change the source mid-share | ✅ | ✅ | ✅ |
| Preview thumbnail while sharing | ✅ | ❌ | ❌ |
| Hardware-accelerated encoding | ✅ | ❌ software | ❌ software |
| H.264 and HEVC | ✅ | ✅ | ✅ |
| Wide gamut / HDR | ✅ | ❌ | ❌ |

¹ On Linux, window sharing goes through the desktop portal: the compositor
shows its own picker and you choose a window there. The option is offered
only when a portal is available (Wayland desktops, and X11 desktops that
run one).

**Wayland works.** On a Wayland session the sharer captures through the
ScreenCast portal, which starts with the compositor's consent dialog; on X11
the screen is captured directly. Sharer-side drawing and remote control are
X11-only today — see the notes below.

## Audio

| | macOS | Linux | Windows |
| :--- | :---: | :---: | :---: |
| Voice chat (speak and listen) | ✅ | ✅ | ✅ |
| Share computer audio | ✅ | ❌ | ❌ |

Viewers on every platform can *hear* shared computer audio — capturing it is
what's macOS-only.

## Annotations and remote control

| | macOS | Linux | Windows |
| :--- | :---: | :---: | :---: |
| Draw on a share as a viewer | ✅ | ✅ | ✅ |
| See viewers' annotations as the sharer | ✅ | ✅ ² | ✅ |
| Draw on your own screen while sharing | ✅ | ✅ ² | ✅ |
| Request and take remote control | ✅ | ✅ | ✅ |
| Grant remote control of your machine | ✅ | ✅ ³ | ✅ ⁴ |
| Panic hotkey to revoke control | ✅ | ❌ | ❌ |
| Zoom + pan as a viewer | ✅ | ✅ | ✅ |

² The sharer-side overlay needs a composited X11 session — any mainstream
desktop qualifies. Without a compositor, or on Wayland, viewers see disabled
drawing tools rather than strokes that go nowhere.

³ Input injection uses X11's XTEST extension; when it's absent, viewers
simply aren't offered "Request control". A headless sharer keeps remote
control off unless started with `--allow-control`.

⁴ Windows declines control and annotations when the share can't be pinned to
one specific monitor — a window share, or two identical displays — rather
than risk clicks landing on a screen the viewer can't see.

## Access control

Viewer approval, remembered allow/block decisions, removing a connected
viewer, and asking a peer to share their screen work on all three platforms.
How admission works is covered in
[Privacy & Security]({{ site.baseurl }}{% link security.md %}).

## Desktop integration

The hub itself — peer list, multiple accounts, quality settings, connection
stats — is fully functional everywhere. The differences are in how the app
integrates with the desktop around it:

| | macOS | Linux | Windows |
| :--- | :---: | :---: | :---: |
| Translated UI | ✅ | ❌ | ❌ |
| Notification when a viewer awaits approval | ✅ | ❌ | ❌ |
| Notification when a viewer joins / leaves | ✅ | ❌ | ❌ |
| Sharing controls outside the main window | ✅ menubar | ❌ | ❌ |
| Mute / unmute via global hotkey | ✅ | ✅ | ✅ |
| Outline around what's being captured | ✅ | ❌ | ⚠️ ⁵ |

⁵ Windows may draw the system's own capture border, depending on OS version.

On macOS the menubar item carries the sharing controls, so you can approve a
viewer, mute, or stop without raising a window over the thing you're sharing.
On Linux and Windows those controls live in the main window today; the
global mute hotkey works everywhere.

## Networking

Everything about the connection itself — encryption, peer-to-peer transport,
loss recovery, congestion control, adaptive quality — is shared code and
identical on all three platforms.

## Installation

| | macOS | Linux | Windows |
| :--- | :---: | :---: | :---: |
| Architectures | Universal (Apple silicon + Intel) | x86_64, aarch64 | x64, arm64 |
| Formats | `.app` zip | AppImage, tarball | zip, MSIX |
| Package manager | Homebrew cask | ❌ | ❌ winget planned |
| Signed | ✅ notarized | — | ⚠️ self-signed ⁶ |

⁶ The Windows MSIX is currently self-signed: trust its certificate once
(each release ships the public `.cer` next to it) and it installs normally —
see [Install]({{ site.baseurl }}{% link install.md %}#installing-the-msix-trusting-the-certificate).
The zip needs no trust step.

Per-platform install steps:
[Install]({{ site.baseurl }}{% link install.md %}).
