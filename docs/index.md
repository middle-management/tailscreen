---
title: Home
layout: home
nav_order: 1
permalink: /
image: /assets/social-card.png
---

<div class="ts-hero">
  <img src="{{ '/assets/logo.svg' | relative_url }}" alt="Tailscreen logo">
  <p class="ts-badges">
    <span class="ts-badge">Open source</span>
    <span class="ts-badge">macOS 15+</span>
    <span class="ts-badge">MIT</span>
  </p>
  <h1>Screen sharing that feels&nbsp;like <span class="ts-accent">sitting at the same Mac</span>.</h1>
  <p class="ts-hero-tagline">Tailscreen streams one Mac&rsquo;s screen to another over your own
  Tailscale network &mdash; encrypted, peer-to-peer, at 60&nbsp;fps. No meeting
  link, no server in the middle, no port to forward.</p>
  <p class="ts-hero-actions">
    <a href="{% link install.md %}" class="btn btn-primary fs-5">Install</a>
    <a href="https://github.com/middle-management/tailscreen" class="btn fs-5">View on GitHub</a>
  </p>
  <p class="ts-hero-note">Free and open source. The only account it needs is the Tailscale login you already have.</p>
</div>

<div class="ts-mock" aria-hidden="true">
  <div class="ts-mock-menubar">
    <span class="ts-mock-mb-menus">
      <span class="ts-mock-mb-menu" style="width: 1.6rem"></span>
      <span class="ts-mock-mb-menu" style="width: 1.1rem"></span>
      <span class="ts-mock-mb-menu" style="width: 1.3rem"></span>
      <span class="ts-mock-mb-menu" style="width: 1.2rem"></span>
    </span>
    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" xmlns="http://www.w3.org/2000/svg">
      <path d="M5 12.5a10 10 0 0 1 14 0"/>
      <path d="M8.5 16a5 5 0 0 1 7 0"/>
      <circle cx="12" cy="19" r="1" fill="currentColor" stroke="none"/>
    </svg>
    <span class="ts-mock-mb-app">
      <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" xmlns="http://www.w3.org/2000/svg">
        <rect x="3" y="4" width="18" height="13" rx="2"/>
        <path d="M9 21h6"/>
        <path d="M12 17v4"/>
      </svg>
    </span>
    <span class="ts-mock-mb-time">Tue 12:04</span>
  </div>
  <div class="ts-mock-window">
    <div class="ts-mock-titlebar">
      <span class="ts-mock-dot ts-mock-dot--red"></span>
      <span class="ts-mock-dot ts-mock-dot--yellow"></span>
      <span class="ts-mock-dot ts-mock-dot--green"></span>
      <span class="ts-mock-title">Viewing robert&rsquo;s MacBook&nbsp;Pro</span>
    </div>
    <div class="ts-mock-screen">
      <span class="ts-mock-route">direct &middot; wireguard</span>
      <div class="ts-mock-code">
        <span class="ts-mock-line is-accent" style="width: 32%"></span>
        <span class="ts-mock-line" style="width: 74%; margin-left: 6%"></span>
        <span class="ts-mock-line" style="width: 58%; margin-left: 6%"></span>
        <span class="ts-mock-line is-green" style="width: 42%; margin-left: 12%"></span>
        <span class="ts-mock-line" style="width: 66%; margin-left: 12%"></span>
        <span class="ts-mock-line" style="width: 30%; margin-left: 6%"></span>
        <span class="ts-mock-line is-accent" style="width: 48%"></span>
        <span class="ts-mock-line" style="width: 70%; margin-left: 6%"></span>
        <span class="ts-mock-line is-green" style="width: 36%; margin-left: 12%"></span>
        <span class="ts-mock-line" style="width: 54%; margin-left: 6%"></span>
      </div>
      <svg class="ts-mock-anno" viewBox="0 0 220 64" fill="none" xmlns="http://www.w3.org/2000/svg">
        <path d="M16 34 C 20 12, 160 4, 196 18 C 214 26, 186 50, 100 54 C 44 56, 10 48, 16 34"
              stroke="currentColor" stroke-width="5" stroke-linecap="round"/>
      </svg>
      <div class="ts-mock-cursor">
        <svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg">
          <path d="M5.5 2.5l13 10.4-6.7 1L9.2 20z" fill="#ffffff" stroke="#20242f"
                stroke-width="1.4" stroke-linejoin="round"/>
        </svg>
        <span class="ts-mock-cursor-label">anna</span>
      </div>
      <span class="ts-mock-stats"><span class="ts-mock-live"></span>60 fps &middot; HEVC &middot; 4.1 Mbit/s</span>
    </div>
  </div>
  <p class="ts-mock-caption">The whole UI is a menubar icon. The viewer is just a window &mdash;
  with someone else&rsquo;s screen in it.</p>
</div>

<div class="ts-stats">
  <div class="ts-stat">
    <span class="ts-stat-n">60&thinsp;fps</span>
    <span class="ts-stat-c">hardware-encoded HEVC, full Retina</span>
  </div>
  <div class="ts-stat">
    <span class="ts-stat-n">Zero</span>
    <span class="ts-stat-c">servers between your Macs</span>
  </div>
  <div class="ts-stat">
    <span class="ts-stat-n">P2P</span>
    <span class="ts-stat-c">WireGuard-encrypted, end to end</span>
  </div>
  <div class="ts-stat">
    <span class="ts-stat-n">100%</span>
    <span class="ts-stat-c">open source, MIT-licensed</span>
  </div>
</div>

ScreenCaptureKit grabs the pixels, VideoToolbox encodes them in hardware,
and [Tailscale](https://tailscale.com/)'s WireGuard tunnel carries them
straight to the other Mac — direct when the network allows, through
Tailscale's DERP relays when it doesn't. Your screen never touches a
third-party server.

## Sharp where it counts

<div class="ts-spotlight">
  <div class="ts-spotlight-icon">
    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" xmlns="http://www.w3.org/2000/svg">
      <polygon points="13 2 3 14 12 14 11 22 21 10 12 10 13 2"/>
    </svg>
  </div>
  <div class="ts-spotlight-body">
    <h3>Video that keeps up</h3>
    <p>Hardware HEVC (H.264 when the other side needs it), wide color that
    survives the trip on P3 displays. And when the network turns ugly,
    Tailscreen fights back instead of freezing: selective retransmission,
    forward error correction, and adaptive bitrate and frame-rate control
    degrade smoothly &mdash; then snap back to full quality the moment the
    link recovers.</p>
  </div>
</div>

<div class="ts-spotlight">
  <div class="ts-spotlight-icon">
    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" xmlns="http://www.w3.org/2000/svg">
      <path d="M12 3l7 3v5c0 4.6-3 7.6-7 9-4-1.4-7-4.4-7-9V6l7-3z"/>
      <path d="M9.5 8.5l5.5 4.3-2.9.5-1.1 2.7z" fill="currentColor" stroke="none"/>
    </svg>
  </div>
  <div class="ts-spotlight-body">
    <h3>Remote control, on your terms</h3>
    <p>A viewer can request your mouse and keyboard &mdash; nothing happens
    until you grant it. One grantee at a time, pointer confined to what
    you&rsquo;re sharing, auto-revoked the instant they disconnect. Take it
    back with one click, or hit <kbd>&#8963;</kbd><kbd>&#8997;</kbd><kbd>.</kbd>
    from anywhere when you want it back <em>right now</em>.</p>
  </div>
</div>

## Everything else you'd expect

<div class="ts-feature-grid">
  <div class="ts-card">
    <div class="ts-card-icon">
      <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" xmlns="http://www.w3.org/2000/svg">
        <path d="M12 3l7 3v5c0 4.6-3 7.6-7 9-4-1.4-7-4.4-7-9V6l7-3z"/>
        <path d="M9 11.5l2 2 4-4"/>
      </svg>
    </div>
    <h3>Approval, on by default</h3>
    <p>Nobody sees a single frame until you Accept them. Remember peers as
    Always Allow &mdash; or Deny &amp; Block.</p>
  </div>
  <div class="ts-card">
    <div class="ts-card-icon">
      <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" xmlns="http://www.w3.org/2000/svg">
        <circle cx="11" cy="11" r="7"/>
        <path d="M16.5 16.5L21 21"/>
      </svg>
    </div>
    <h3>Finds your Macs for you</h3>
    <p>Tailscreen probes your tailnet and lists who&rsquo;s sharing.
    You&rsquo;ll never type an IP address.</p>
  </div>
  <div class="ts-card">
    <div class="ts-card-icon">
      <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" xmlns="http://www.w3.org/2000/svg">
        <polygon points="11 5 6 9 2 9 2 15 6 15 11 19 11 5"/>
        <path d="M15.5 8.5a5 5 0 0 1 0 7"/>
        <path d="M19 5a10 10 0 0 1 0 14"/>
      </svg>
    </div>
    <h3>Voice &amp; system audio</h3>
    <p>Talk over the same tunnel, and share what your Mac is playing.
    Viewers hear both; everyone gets a mute button.</p>
  </div>
  <div class="ts-card">
    <div class="ts-card-icon">
      <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" xmlns="http://www.w3.org/2000/svg">
        <path d="M12 20h9"/>
        <path d="M16.5 3.5a2.1 2.1 0 0 1 3 3L7 19l-4 1 1-4L16.5 3.5z"/>
      </svg>
    </div>
    <h3>Draw on the screen</h3>
    <p>Two-way annotations ride a reliable back-channel, so strokes land
    even when the network is dropping video packets.</p>
  </div>
  <div class="ts-card">
    <div class="ts-card-icon">
      <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" xmlns="http://www.w3.org/2000/svg">
        <rect x="2" y="3" width="20" height="14" rx="2"/>
        <path d="M8 21h8"/>
        <path d="M12 17v4"/>
      </svg>
    </div>
    <h3>A real viewer window</h3>
    <p>Cursor-anchored zoom and pan, a live stats overlay, and quality
    presets for when bandwidth is precious.</p>
  </div>
  <div class="ts-card">
    <div class="ts-card-icon">
      <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" xmlns="http://www.w3.org/2000/svg">
        <path d="M9.6 4.6A2 2 0 1 1 11 8H2"/>
        <path d="M12.6 19.4A2 2 0 1 0 14 16H2"/>
        <path d="M17.7 7.7A2.5 2.5 0 1 1 19.5 12H2"/>
      </svg>
    </div>
    <h3>Leaves no trace in your tailnet</h3>
    <p>Every session runs an ephemeral Tailscale node that vanishes when
    you stop. No ghost machines in your admin console.</p>
  </div>
</div>

## How it works

<div class="ts-steps">
  <div class="ts-step">
    <span class="ts-step-n">1</span>
    <h3>You hit Start Sharing</h3>
    <p>Pick a display, a window, or an app from the native macOS picker.</p>
  </div>
  <div class="ts-step">
    <span class="ts-step-n">2</span>
    <h3>They hit Browse Shares</h3>
    <p>Your Mac shows up by name on their menubar. They click it.</p>
  </div>
  <div class="ts-step">
    <span class="ts-step-n">3</span>
    <h3>A window opens</h3>
    <p>That&rsquo;s the whole thing. No links, no PINs, no calendar invite.</p>
  </div>
</div>

## What you need

<ul class="ts-checks">
  <li>macOS 15 (Sequoia) or later, on both ends. Earlier macOS versions, iOS, and Linux aren&rsquo;t supported.</li>
  <li>A Tailscale account &mdash; the free personal tier is fine.</li>
  <li>Screen Recording permission; macOS asks the first time you share.
  (Accessibility too, but only if you ever grant remote control.)</li>
  <li>A Swift 6 toolchain &mdash; only if you&rsquo;re building from source.</li>
</ul>

## Where to go next

| You want to...                                  | Read this                                        |
| :---------------------------------------------- | :----------------------------------------------- |
| Get it running                                  | [Install]({% link install.md %})                 |
| Actually use it                                 | [Usage]({% link usage.md %})                     |
| See how the pieces fit together                 | [Architecture]({% link architecture.md %})       |
| Read the wire format                            | [Network Protocol]({% link protocol.md %})       |
| Confirm nobody else is watching                 | [Privacy & Security]({% link security.md %})     |
| Diagnose a black viewer window                  | [Troubleshooting]({% link troubleshooting.md %}) |
| Hack on it                                      | [Contributing]({% link contributing.md %})       |

## License

[MIT](https://github.com/middle-management/tailscreen/blob/main/LICENSE).
The upstream `libtailscale` is BSD-3-Clause. Do whatever.

<div class="ts-cta">
  <h2>Your screen, on their Mac, in seconds.</h2>
  <p>Install it, sign in to Tailscale, hit Start Sharing.</p>
  <p class="ts-cta-actions">
    <a href="{% link install.md %}" class="btn btn-primary fs-5">Install Tailscreen</a>
    <a href="{% link usage.md %}" class="btn fs-5">Read the usage guide</a>
  </p>
</div>
