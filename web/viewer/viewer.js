// The Phase 2 spike loop. Everything wire-shaped comes from the wasm exports
// (sdk/go under the hood); this file only sequences them:
//
//   load wasm → dial by token → HELLO as a mediaDatagram frame → keep HELLO
//   going until answered, then KEEPALIVE at the spec cadence → classify every
//   frame that comes back and count it.
//
// `window.__spike` is the observable state the Playwright harness asserts on.

"use strict";

const spike = (window.__spike = {
  state: "loading",
  serverAddr: null,
  ssrc: null,
  rtpPackets: 0,
  rtpBytes: 0,
  video: 0,
  audio: 0,
  control: {},
  otherFrames: {},
  lastError: null,
  log: [],
});

const $ = (id) => document.getElementById(id);

function log(line) {
  spike.log.push(line);
  console.log(line);
  const el = $("log");
  if (el) el.textContent += line + "\n";
}

function render() {
  $("state").textContent = spike.state + (spike.lastError ? ` — ${spike.lastError}` : "");
  $("server").textContent = spike.serverAddr ?? "—";
  $("ssrc").textContent = spike.ssrc ?? "—";
  $("rtp").textContent = `${spike.rtpPackets} (video ${spike.video}, audio ${spike.audio}), ${spike.rtpBytes} bytes`;
  $("control").textContent =
    Object.entries(spike.control)
      .map(([k, v]) => `${k}×${v}`)
      .join(", ") || "—";
}

function fail(err) {
  spike.lastError = String(err?.message ?? err);
  spike.state = "error";
  log("ERROR " + spike.lastError);
  render();
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

async function loadWasm() {
  const go = new Go();
  const result = await WebAssembly.instantiateStreaming(fetch("dist/viewer.wasm"), go.importObject);
  // main() installs the exports and then parks, so this promise never
  // settles while the module is useful; don't await it.
  go.run(result.instance).catch(fail);
  await waitFor(() => globalThis.tailscreenReady === true);
}

function tokenFromLocation() {
  const hash = location.hash.replace(/^#/, "");
  if (hash.startsWith("tc")) return hash;
  const q = new URLSearchParams(location.search).get("token");
  return q && q.startsWith("tc") ? q : null;
}

async function run(token) {
  const K = tailscreenConstants;
  const MD = K.mediaDatagramType;

  spike.state = "dialing";
  render();
  const conn = await tailscreenGuestDial(token, K.port);
  spike.serverAddr = conn.serverAddr;
  spike.state = "connected";
  log(`tunnel up: sharer at ${conn.serverAddr}, our node key ${conn.publicKey}`);
  render();

  const send = (dgram) => conn.write(tailscreenFrameEncode(MD, dgram));

  // TS-STM-002: the HELLO rides the framed connection — that IS the election.
  // Legacy one-byte HELLO for the spike (no caps ⇒ no NACK/FEC, TS-STM-005;
  // RR comes with Phase 3). Re-sent on the keepalive cadence until the sharer
  // answers, then KEEPALIVE keeps the idle sweep at bay (TS-STM-004).
  await send(tailscreenHello(0));
  spike.state = "hello-sent";
  render();
  const cadence = setInterval(() => {
    const answered = spike.state === "acked" || spike.state === "pending";
    send(answered ? tailscreenControl("keepalive") : tailscreenHello(0)).catch(() => {});
  }, K.keepaliveMs);

  const parser = tailscreenNewFrameParser();
  try {
    for (;;) {
      const chunk = await conn.read();
      if (chunk === null) {
        log("connection closed by the sharer (SERVER_BYE equivalent, TS-STM-004)");
        break;
      }
      parser.append(chunk);
      let frame;
      while ((frame = parser.next()) !== null) {
        if (frame.type !== MD) {
          spike.otherFrames[frame.type] = (spike.otherFrames[frame.type] ?? 0) + 1;
          continue;
        }
        const c = tailscreenClassify(frame.payload);
        if (c.class === "rtp") {
          spike.rtpPackets++;
          spike.rtpBytes += frame.payload.byteLength;
          if (c.pt === K.pt.h264 || c.pt === K.pt.hevc) spike.video++;
          else spike.audio++;
          continue;
        }
        if (c.class !== "control") continue;
        const name = c.name ?? `0x${c.kind.toString(16)}`;
        spike.control[name] = (spike.control[name] ?? 0) + 1;
        switch (c.name) {
          case "helloAck":
            if (spike.state !== "acked") log(`admitted: HELLO_ACK ssrc=${c.ssrc} serverCaps=${c.serverCaps ?? 0}`);
            spike.state = "acked";
            spike.ssrc = c.ssrc;
            break;
          case "helloPending":
            if (spike.state !== "acked" && spike.state !== "pending") log("parked: HELLO_PENDING (waiting for the sharer to approve)");
            if (spike.state !== "acked") spike.state = "pending";
            break;
          case "helloDenied":
            log("declined: HELLO_DENY");
            spike.state = "denied";
            break;
          case "serverBye":
            log("sharer stopped: SERVER_BYE");
            spike.state = "ended";
            break;
        }
      }
      if (parser.corrupt()) {
        spike.lastError = "corrupt frame stream (oversized length)";
        break;
      }
      render();
    }
  } finally {
    clearInterval(cadence);
    if (spike.state !== "ended" && spike.state !== "denied" && spike.state !== "error") spike.state = "closed";
    render();
    conn.close().catch(() => {});
  }
}

(async () => {
  try {
    await loadWasm();
    const token = tokenFromLocation();
    if (!token) {
      spike.state = "no-token";
      $("notoken").hidden = false;
      render();
      return;
    }
    await run(token);
  } catch (err) {
    fail(err);
  }
})();
