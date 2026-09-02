// The browser viewer (plans/browser-viewer.md, Phase 3). The wasm owns the
// protocol — guest tunnel, framing, the receive pipeline, the cadences —
// and this file owns what a browser has that Go does not: WebCodecs, a
// canvas, an AudioContext, and the person in front of them.
//
//   load wasm → dial by token → session (HELLO over the stream profile) →
//   every returning frame → session.ingest → access units → VideoDecoder →
//   canvas; Opus frames → AudioDecoder → AudioContext (behind a gesture).
//
// `window.__viewer` is the observable state the e2e asserts on.

"use strict";

const viewer = (window.__viewer = {
  state: "loading",
  serverAddr: null,
  ssrc: null,
  hostname: null,
  shareName: null,
  codec: null,
  codecString: null,
  width: 0,
  height: 0,
  decodedFrames: 0,
  decodeErrors: 0,
  droppedAUs: 0,
  videoAUs: 0,
  keyframes: 0,
  rtpVideo: 0,
  audioFrames: 0,
  fps: 0,
  kbps: 0,
  unsupported: false,
  serverCaps: 0,
  controlling: false,
  annotationsReceived: 0,
  lastError: null,
  log: [],
});

const $ = (id) => document.getElementById(id);
const K = () => tailscreenConstants;
const nowNs = () => performance.now() * 1e6;

// --- strings: the shared catalog, exported at build time -----------------------

let STR = {};
async function loadStrings() {
  try {
    const all = window.__tailscreenInlineStrings ?? (await (await fetch("dist/strings.json")).json());
    for (const l of navigator.languages ?? [navigator.language]) {
      const lang = String(l).toLowerCase().split("-")[0];
      if (all[lang]) {
        STR = all[lang];
        return;
      }
    }
    STR = all.en ?? {};
  } catch {
    STR = {};
  }
}
// The key IS the English text, so a missing catalog degrades to English.
const t = (key, arg) => (STR[key] ?? key).replace("%@", arg ?? "");

// --- small UI ----------------------------------------------------------------------------

function log(line) {
  viewer.log.push(line);
  if (viewer.log.length > 200) viewer.log.shift();
  console.log(line);
  const el = $("log");
  if (el) el.textContent = viewer.log.join("\n");
}

function placard(title, body = "", action = null) {
  const p = $("placard");
  if (title === null) {
    p.hidden = true;
    return;
  }
  p.hidden = false;
  $("placard-title").textContent = title;
  $("placard-body").textContent = body;
  const b = $("placard-action");
  b.hidden = !action;
  if (action) {
    b.textContent = action.label;
    b.onclick = action.onClick;
  }
}

function fail(err) {
  viewer.lastError = String(err?.message ?? err);
  viewer.state = "error";
  log("ERROR " + viewer.lastError);
  placard(t("Session Ended"), viewer.lastError, { label: t("Reconnect"), onClick: () => location.reload() });
}

function waitFor(pred, timeoutMs = 20_000) {
  return new Promise((resolve, reject) => {
    const t0 = Date.now();
    const tick = () => {
      if (pred()) return resolve();
      if (Date.now() - t0 > timeoutMs) return reject(new Error("timed out"));
      setTimeout(tick, 20);
    };
    tick();
  });
}

// The wasm is 34 MB raw and 7.8 MB gzipped, and static hosts (GitHub Pages
// among them) will not compress application/wasm on the fly — so the page
// fetches the pre-compressed .gz and inflates it itself, falling back to the
// raw file only where DecompressionStream is missing. The single-file bundle
// (tools/bundle.py) inlines the same .gz as base64 and takes the same path.
async function wasmResponse() {
  const inline = window.__tailscreenInlineWasmGzB64;
  const canInflate = typeof DecompressionStream === "function";
  if (inline) {
    if (!canInflate) throw new Error("this browser cannot inflate the bundled viewer (no DecompressionStream)");
    const bytes = Uint8Array.from(atob(inline), (c) => c.charCodeAt(0));
    const stream = new Blob([bytes]).stream().pipeThrough(new DecompressionStream("gzip"));
    return new Response(stream, { headers: { "Content-Type": "application/wasm" } });
  }
  if (canInflate) {
    const gz = await fetch("dist/viewer.wasm.gz");
    if (gz.ok && gz.body) {
      const stream = gz.body.pipeThrough(new DecompressionStream("gzip"));
      return new Response(stream, { headers: { "Content-Type": "application/wasm" } });
    }
  }
  return fetch("dist/viewer.wasm");
}

async function loadWasm() {
  const go = new Go();
  const result = await WebAssembly.instantiateStreaming(wasmResponse(), go.importObject);
  go.run(result.instance).catch(fail); // main() parks; never settles while useful
  await waitFor(() => globalThis.tailscreenReady === true);
}

function tokenFromLocation() {
  const hash = location.hash.replace(/^#/, "");
  if (hash.startsWith("tc")) return hash;
  const q = new URLSearchParams(location.search).get("token");
  return q && q.startsWith("tc") ? q : null;
}

const rtpToMicros = (ts, clock) => Math.round((ts * 1e6) / clock);
const hex = (u8) => (u8 ? Array.from(u8, (b) => b.toString(16).padStart(2, "0")).join("") : "");

// avcC (ISO 14496-15) from the in-band SPS/PPS — WebCodecs' "avc" format,
// the one every engine accepts, fed with the depacketizer's AVCC as-is.
function avcC(sps, pps) {
  const out = new Uint8Array(11 + sps.length + pps.length);
  out.set([1, sps[1], sps[2], sps[3], 0xff, 0xe1, sps.length >> 8, sps.length & 0xff], 0);
  out.set(sps, 8);
  let i = 8 + sps.length;
  out.set([1, pps.length >> 8, pps.length & 0xff], i);
  out.set(pps, i + 3);
  return out;
}

// --- video: WebCodecs → canvas --------------------------------------------------------------

class VideoPath {
  constructor(session, canvas) {
    this.session = session;
    this.canvas = canvas;
    this.ctx = canvas.getContext("2d");
    this.decoder = null;
    this.configKey = null;
    this.awaitingKeyframe = true;
    this.queue = Promise.resolve(); // AUs are handled strictly in order
    this.framesThisSecond = 0;
  }

  handle(au) {
    this.queue = this.queue.then(() => this.handleNow(au)).catch((e) => this.onError(e));
  }

  async handleNow(au) {
    if (viewer.unsupported) return;
    if (au.keyframe && au.sps && (au.codec === "hevc" || au.pps)) {
      const key = `${au.codec}:${au.codecString}:${hex(au.sps)}:${hex(au.pps)}:${hex(au.vps)}`;
      if (key !== this.configKey) {
        if (!(await this.configure(au))) return;
        this.configKey = key;
      }
    }
    if (!this.decoder || this.decoder.state !== "configured") {
      viewer.droppedAUs++;
      return; // a keyframe with parameter sets will configure us; the session asks for one
    }
    if (this.awaitingKeyframe && !au.keyframe) {
      viewer.droppedAUs++;
      return;
    }
    if (this.decoder.decodeQueueSize > 12 && !au.keyframe) {
      // Falling behind: shed to the next keyframe rather than build latency.
      viewer.droppedAUs++;
      this.awaitingKeyframe = true;
      this.session.requestKeyframe();
      return;
    }
    const data = au.codec === "hevc" ? au.annexb : au.avcc;
    this.decoder.decode(
      new EncodedVideoChunk({ type: au.keyframe ? "key" : "delta", timestamp: rtpToMicros(au.timestamp, 90_000), data }),
    );
    this.awaitingKeyframe = false;
  }

  async configure(au) {
    const config =
      au.codec === "hevc"
        ? { codec: au.codecString || "hev1.1.6.L93.B0", optimizeForLatency: true }
        : { codec: au.codecString, description: avcC(au.sps, au.pps), optimizeForLatency: true };
    let supported = false;
    try {
      supported = (await VideoDecoder.isConfigSupported(config)).supported;
    } catch {
      supported = false;
    }
    if (!supported) {
      if (au.codec === "hevc") {
        // The existing escape hatch: CODEC_NO latches the share to H.264.
        log(`HEVC (${config.codec}) is not decodable here — asking the sharer for H.264`);
        this.session.codecUnsupported();
        return false;
      }
      viewer.unsupported = true;
      viewer.state = "unsupported";
      log(`this browser cannot decode ${config.codec}`);
      placard(t("Session Ended"), `This browser cannot decode ${config.codec}. Chrome, Edge, Safari and Firefox can.`);
      return false;
    }
    this.close();
    this.decoder = new VideoDecoder({ output: (f) => this.onFrame(f), error: (e) => this.onError(e) });
    this.decoder.configure(config);
    this.awaitingKeyframe = true;
    viewer.codec = au.codec;
    viewer.codecString = config.codec;
    log(`decoder configured: ${config.codec}`);
    return true;
  }

  onFrame(frame) {
    try {
      if (this.canvas.width !== frame.displayWidth || this.canvas.height !== frame.displayHeight) {
        this.canvas.width = frame.displayWidth;
        this.canvas.height = frame.displayHeight;
        viewer.width = frame.displayWidth;
        viewer.height = frame.displayHeight;
        this.onResize?.(frame.displayWidth, frame.displayHeight);
      }
      this.ctx.drawImage(frame, 0, 0);
      viewer.decodedFrames++;
      this.framesThisSecond++;
    } finally {
      frame.close();
    }
  }

  onError(err) {
    viewer.decodeErrors++;
    log("decode error: " + (err?.message ?? err));
    this.close();
    this.configKey = null;
    this.awaitingKeyframe = true;
    this.session.requestKeyframe();
  }

  close() {
    try {
      this.decoder?.close();
    } catch {}
    this.decoder = null;
  }
}

// --- audio: Opus → AudioContext, behind a gesture ---------------------------------------------

class AudioPath {
  constructor() {
    this.ctx = null;
    this.decoders = new Map(); // ssrc → AudioDecoder
    this.next = new Map(); // ssrc → next scheduled start time
    this.enabled = false;
    this.muted = false;
  }

  enable() {
    if (!this.ctx) this.ctx = new AudioContext({ sampleRate: 48_000 });
    this.ctx.resume();
    this.enabled = true;
  }

  handle(fr) {
    if (!this.enabled || this.muted) return;
    let d = this.decoders.get(fr.ssrc);
    if (!d) {
      d = new AudioDecoder({
        output: (data) => this.play(fr.ssrc, data),
        error: (e) => {
          log(`audio decode error (ssrc ${fr.ssrc}): ${e.message}`);
          this.decoders.delete(fr.ssrc);
        },
      });
      d.configure({ codec: "opus", sampleRate: 48_000, numberOfChannels: 1 });
      this.decoders.set(fr.ssrc, d);
    }
    try {
      d.decode(new EncodedAudioChunk({ type: "key", timestamp: rtpToMicros(fr.timestamp, 48_000), data: fr.payload }));
      viewer.audioFrames++;
    } catch (e) {
      log("audio chunk rejected: " + e.message);
    }
  }

  play(ssrc, data) {
    try {
      const n = data.numberOfFrames;
      const buf = this.ctx.createBuffer(1, n, data.sampleRate);
      const f32 = new Float32Array(n);
      data.copyTo(f32, { planeIndex: 0, format: "f32-planar" });
      buf.copyToChannel(f32, 0);
      const src = this.ctx.createBufferSource();
      src.buffer = buf;
      src.connect(this.ctx.destination);
      const now = this.ctx.currentTime;
      let at = this.next.get(ssrc) ?? 0;
      if (at < now + 0.02 || at > now + 0.5) at = now + 0.06; // (re)anchor with a small lead
      src.start(at);
      this.next.set(ssrc, at + buf.duration);
    } finally {
      data.close();
    }
  }
}

// --- the session ---------------------------------------------------------------------------------

async function run(token) {
  const Kc = K();
  const MD = Kc.mediaDatagramType;
  placard(t("Connecting…"));
  viewer.state = "dialing";

  const conn = await tailscreenGuestDial(token, Kc.port);
  viewer.serverAddr = conn.serverAddr;
  log(`tunnel up: sharer at ${conn.serverAddr}, our node key ${conn.publicKey}`);

  const session = tailscreenNewSession({});
  const video = new VideoPath(session, $("stage"));
  const audio = new AudioPath();
  const send = (dgram) => conn.write(tailscreenFrameEncode(MD, dgram)).catch(() => {});

  // Who are we watching? Same connection, answered on it (§13.2).
  conn.write(tailscreenFrameEncode(Kc.metadataRequestType)).catch(() => {});

  const W = TailscreenWire;
  const utf8 = new TextEncoder();
  const sendFrame = (type, obj) =>
    conn.write(tailscreenFrameEncode(type, obj === undefined ? undefined : utf8.encode(JSON.stringify(obj)))).catch(() => {});

  // --- remote control (§12): request → granted → input events on the stage ---
  const ink = $("ink");
  const inkCtx = ink.getContext("2d");
  const norm = (e) => {
    const r = ink.getBoundingClientRect();
    return [Math.min(1, Math.max(0, (e.clientX - r.left) / r.width)), Math.min(1, Math.max(0, (e.clientY - r.top) / r.height))];
  };
  const setControlling = (on) => {
    viewer.controlling = on;
    document.body.classList.toggle("controlling", on);
    $("btn-control").textContent = on ? "Release control" : "Request control";
    $("btn-control").classList.toggle("active", on);
    if (on) {
      mode = "control";
      document.body.classList.remove("drawing");
      $("btn-draw").classList.remove("active");
    } else if (mode === "control") mode = null;
  };
  let mode = null; // "control" | "draw" | null — the overlay serves one at a time
  $("btn-control").onclick = () => {
    if (viewer.controlling) {
      sendFrame(Kc.controlReleasedType); // TS-RMT-006
      setControlling(false);
    } else {
      sendFrame(Kc.controlRequestType);
      log("control requested");
    }
  };
  let lastMoveAt = 0;
  ink.addEventListener("pointermove", (e) => {
    if (mode === "control") {
      const now = performance.now();
      if (now - lastMoveAt < 16) return; // the sharer enforces a rate ceiling (TS-RMT-007); be a good citizen
      lastMoveAt = now;
      const [x, y] = norm(e);
      sendFrame(Kc.inputEventType, W.input.mouseMove(x, y));
    } else if (mode === "draw" && stroke) {
      stroke.points.push(norm(e));
      renderInk();
    }
  });
  ink.addEventListener("pointerdown", (e) => {
    if (mode === "control") {
      const b = W.input.button(e);
      if (!b) return;
      ink.setPointerCapture(e.pointerId);
      const [x, y] = norm(e);
      sendFrame(Kc.inputEventType, W.input.mouseDown(x, y, b, W.modifiers(e)));
    } else if (mode === "draw") {
      ink.setPointerCapture(e.pointerId);
      stroke = { points: [norm(e)] };
    }
  });
  ink.addEventListener("pointerup", (e) => {
    if (mode === "control") {
      const b = W.input.button(e);
      if (!b) return;
      const [x, y] = norm(e);
      sendFrame(Kc.inputEventType, W.input.mouseUp(x, y, b, W.modifiers(e)));
    } else if (mode === "draw" && stroke) {
      stroke.points.push(norm(e));
      const [r, g, b] = $("sel-color").value.split(",").map(Number);
      const op = W.annotation.add("pen", stroke.points, { r, g, b, a: 1 }, 0.004);
      stroke = null;
      annotations.apply(op);
      mine.push(op.annotation.id);
      renderInk();
      sendFrame(Kc.annotationType, op);
    }
  });
  ink.addEventListener("contextmenu", (e) => mode && e.preventDefault());
  ink.addEventListener(
    "wheel",
    (e) => {
      if (mode !== "control") return;
      e.preventDefault();
      const [x, y] = norm(e);
      const [dx, dy] = W.input.lines(e);
      sendFrame(Kc.inputEventType, W.input.scroll(x, y, dx, dy, W.modifiers(e)));
    },
    { passive: false },
  );
  const keyHandler = (kind) => (e) => {
    if (mode !== "control" || e.target !== document.body) return;
    const usage = W.input.usage(e);
    if (usage === null) return; // modifiers ride the bit field, never as keys (TS-RMT-025)
    e.preventDefault();
    sendFrame(Kc.inputEventType, kind === "down" ? W.input.keyDown(usage, W.modifiers(e)) : W.input.keyUp(usage, W.modifiers(e)));
  };
  document.addEventListener("keydown", keyHandler("down"));
  document.addEventListener("keyup", keyHandler("up"));

  // --- annotations (§11): draw, and render what the sharer relays ---
  const annotations = new W.AnnotationStore();
  const mine = [];
  let stroke = null;
  const renderInk = () => {
    annotations.render(inkCtx, ink.width, ink.height);
    if (stroke) {
      const [r, g, b] = $("sel-color").value.split(",").map(Number);
      W.AnnotationStore.prototype.render.call(
        { items: new Map([["live", { tool: "pen", points: stroke.points, color: { r, g, b, a: 1 }, width: 0.004 }]]) },
        inkCtx, ink.width, ink.height,
      );
    }
  };
  video.onResize = (w, h) => {
    ink.width = w;
    ink.height = h;
    renderInk();
  };
  $("btn-draw").onclick = () => {
    const on = mode !== "draw";
    if (on && viewer.controlling) {
      sendFrame(Kc.controlReleasedType);
      setControlling(false);
    }
    mode = on ? "draw" : null;
    document.body.classList.toggle("drawing", on);
    $("btn-draw").classList.toggle("active", on);
  };
  $("btn-undo").onclick = () => {
    const id = mine.pop();
    if (!id) return;
    annotations.apply(W.annotation.undo(id));
    renderInk();
    sendFrame(Kc.annotationType, W.annotation.undo(id));
  };
  $("btn-clear").onclick = () => {
    annotations.apply(W.annotation.clearAll());
    mine.length = 0;
    renderInk();
    sendFrame(Kc.annotationType, W.annotation.clearAll());
  };
  // The sharer's advertised capabilities decide what the toolbar offers:
  // bit 3 remoteControl ("this host can inject"), bit 4 annotations ("this
  // host renders/relays strokes") — hidden rather than disabled, like the apps.
  const applyCaps = (caps) => {
    viewer.serverCaps = caps;
    $("btn-control").hidden = !(caps & 8);
    for (const id of ["btn-draw", "sel-color", "btn-undo", "btn-clear"]) $(id).hidden = !(caps & 16);
  };

  $("btn-audio").onclick = () => {
    if (!audio.enabled) {
      audio.enable();
      $("btn-audio").textContent = t("Mute System Audio");
    } else {
      audio.muted = !audio.muted;
      $("btn-audio").textContent = audio.muted ? "Unmute audio" : t("Mute System Audio");
    }
  };
  $("btn-stats").onclick = () => ($("hud").hidden = !$("hud").hidden);
  $("btn-log").onclick = () => ($("log").hidden = !$("log").hidden);
  $("btn-full").onclick = () => document.documentElement.requestFullscreen?.().catch(() => {});
  document.addEventListener("keydown", (e) => {
    if (e.key === "s") $("hud").hidden = !$("hud").hidden;
  });

  let lastBytes = 0;
  let ticks = 0;
  const syncState = () => {
    const s = session.state();
    viewer.ssrc = s.ssrc || viewer.ssrc;
    viewer.videoAUs = s.stats.videoAUs;
    viewer.keyframes = s.stats.keyframes;
    viewer.rtpVideo = s.stats.rtpVideo;
    if (!viewer.unsupported && viewer.state !== "error") {
      const prev = viewer.state;
      viewer.state = s.state === "acked" ? "acked" : s.state === "connecting" ? "hello-sent" : s.state;
      if (viewer.state !== prev) {
        switch (viewer.state) {
          case "pending":
            placard(t("Waiting for approval"), t("The sharer needs to accept you as a viewer."));
            break;
          case "acked":
            log(`admitted: ssrc=${s.ssrc} serverCaps=${s.serverCaps}`);
            applyCaps(s.serverCaps);
            placard(null);
            break;
          case "denied":
            placard(t("Declined"), t("The sharer declined your request to view their screen."));
            break;
          case "ended":
            placard(t("Sharing Stopped"), "", { label: t("Reconnect"), onClick: () => location.reload() });
            break;
        }
      }
    }
    if (++ticks % 10 === 0) {
      viewer.fps = video.framesThisSecond;
      video.framesThisSecond = 0;
      viewer.kbps = Math.round(((s.stats.rtpBytes - lastBytes) * 8) / 1000);
      lastBytes = s.stats.rtpBytes;
      $("hud").textContent =
        `${viewer.state}  ${viewer.codecString ?? "—"}  ${viewer.width}×${viewer.height}\n` +
        `${viewer.fps} fps  ${viewer.kbps} kbps  decoded ${viewer.decodedFrames}  dropped ${viewer.droppedAUs}  errors ${viewer.decodeErrors}\n` +
        `AUs ${s.stats.videoAUs}  key ${s.stats.keyframes}  torn ${s.stats.tornAUs}  gaps ${s.stats.skippedGaps}  ` +
        `PLI ${s.stats.pliSent}  RR ${s.stats.reports}  audio ${viewer.audioFrames}`;
    }
  };
  const ticker = setInterval(() => {
    for (const d of session.tick(nowNs())) send(d);
    syncState();
  }, 100);

  const parser = tailscreenNewFrameParser();
  try {
    for (;;) {
      const chunk = await conn.read();
      if (chunk === null) {
        log("connection closed by the sharer");
        break;
      }
      parser.append(chunk);
      let frame;
      while ((frame = parser.next()) !== null) {
        if (frame.type === MD) {
          const r = session.ingest(frame.payload, nowNs());
          for (const au of r.video) video.handle(au);
          for (const fr of r.audio) audio.handle(fr);
          continue;
        }
        if (frame.type === Kc.annotationType) {
          try {
            if (annotations.apply(JSON.parse(new TextDecoder().decode(frame.payload)))) {
              viewer.annotationsReceived++;
              renderInk();
            }
          } catch {}
          continue;
        }
        if (frame.type === Kc.controlGrantedType) {
          log("control granted");
          setControlling(true);
          continue;
        }
        if (frame.type === Kc.controlRevokedType) {
          let reason = "";
          try {
            reason = JSON.parse(new TextDecoder().decode(frame.payload)).reason ?? "";
          } catch {}
          log("control revoked" + (reason ? `: ${reason}` : ""));
          setControlling(false);
          continue;
        }
        if (frame.type === Kc.metadataResponseType) {
          const m = tailscreenDecodeMetadata(frame.payload);
          if (m) {
            viewer.hostname = m.hostname;
            viewer.shareName = m.shareName;
            const who = m.shareName || m.hostname || t("Shared screen");
            document.title = t("Watching %@", who);
            log(`sharer: ${who} (${m.width}×${m.height}, ${m.videoCodec || "h264"})`);
          }
        }
      }
      if (parser.corrupt()) throw new Error("corrupt frame stream (oversized length)");
    }
  } finally {
    clearInterval(ticker);
    syncState();
    if (!["denied", "ended", "error", "unsupported"].includes(viewer.state)) {
      viewer.state = "closed";
      placard(t("Session Ended"), "", { label: t("Reconnect"), onClick: () => location.reload() });
    }
    video.close();
    conn.close().catch(() => {});
  }
}

(async () => {
  try {
    await loadStrings();
    placard("Tailscreen", "Loading…");
    await loadWasm();
    const token = tokenFromLocation();
    if (!token) {
      viewer.state = "no-token";
      placard("Tailscreen", "Open the link a sharer gave you — this page needs a tc… token in its URL.");
      return;
    }
    await run(token);
  } catch (err) {
    fail(err);
  }
})();
