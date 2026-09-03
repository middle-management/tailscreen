// The page's audio path, with no sharer: real Opus packets (gen_opus.py,
// libopus) fed to `AudioPath` in a real browser, asserting the whole chain
// the browser↔sharer spike cannot reach — the headless sharer sends no
// audio. Decode through WebCodecs, output scheduled on the AudioContext,
// audible samples, the per-type counters the HUD shows, and (Chromium, where
// the autoplay flag stands in for the click) a running context. Firefox is
// asserted on everything but the context state: headless, no gesture, it
// stays suspended by design. `PW_BROWSER=firefox` runs it there.
import { createRequire } from "node:module";
import { execFileSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import http from "node:http";
import path from "node:path";
import { fileURLToPath } from "node:url";

const require = createRequire(import.meta.url);
const pw = require(process.env.PLAYWRIGHT_MODULE ?? "playwright");
const here = path.dirname(fileURLToPath(import.meta.url));
const viewerDir = path.resolve(here, "..");
const engine = process.env.PW_BROWSER ?? "chromium";
const channel = process.env.PW_CHANNEL ?? (existsSync("/opt/google/chrome/chrome") ? "chrome" : undefined);
const log = (...a) => console.log("[audio.test]", ...a);

const packets = JSON.parse(execFileSync("python3", [path.join(here, "gen_opus.py"), "-"]).toString());

const mime = { ".html": "text/html", ".js": "text/javascript", ".wasm": "application/wasm", ".json": "application/json", ".gz": "application/gzip" };
const srv = http.createServer((req, res) => {
  const p = path.join(viewerDir, decodeURIComponent(new URL(req.url, "http://x").pathname));
  if (!existsSync(p)) { res.writeHead(404); res.end(); return; }
  res.writeHead(200, { "Content-Type": mime[path.extname(p)] ?? "application/octet-stream" });
  res.end(readFileSync(p));
});
await new Promise((r) => srv.listen(0, "127.0.0.1", r));
const port = srv.address().port;

const noProxy = { ...process.env, HTTPS_PROXY: "", HTTP_PROXY: "", https_proxy: "", http_proxy: "" };
const browser = await pw[engine].launch(
  engine === "chromium"
    ? { channel, args: ["--autoplay-policy=no-user-gesture-required", "--no-proxy-server"], env: noProxy }
    : { firefoxUserPrefs: { "network.proxy.type": 0 }, env: noProxy },
);
const page = await browser.newPage();
const pageErrors = [];
page.on("pageerror", (e) => pageErrors.push(e.message));
await page.goto(`http://127.0.0.1:${port}/index.html`);
await page.waitForFunction(() => typeof AudioPath === "function" && window.__viewer?.state === "no-token", null, { timeout: 60_000 });

const feed = (pt) =>
  page.evaluate(
    async ({ packets, pt }) => {
      const a = new AudioPath();
      const out = { rms: 0 };
      const origPlay = a.play.bind(a);
      a.play = (ssrc, data) => {
        const n = data.numberOfFrames;
        const f32 = new Float32Array(n);
        data.clone().copyTo(f32, { planeIndex: 0, format: "f32-planar" });
        let s = 0;
        for (const v of f32) s += v * v;
        out.rms = Math.max(out.rms, Math.sqrt(s / n));
        origPlay(ssrc, data);
      };
      if (!a.enable()) return { ...out, unsupported: true };
      let ts = 0;
      for (const b64 of packets) {
        const bin = atob(b64);
        const u8 = new Uint8Array(bin.length);
        for (let i = 0; i < bin.length; i++) u8[i] = bin.charCodeAt(i);
        a.handle({ ssrc: pt === 98 ? 0 : 1, pt, seq: 0, timestamp: ts, payload: u8 });
        ts += 960;
        await new Promise((r) => setTimeout(r, 20));
      }
      await new Promise((r) => setTimeout(r, 400));
      const v = window.__viewer;
      return { ...out, voice: v.audioVoice, system: v.audioSystem, played: v.audioPlayed, errors: v.audioPlayErrors, ctx: a.ctx.state, log: v.log.filter((l) => /audio/i.test(l)) };
    },
    { packets, pt },
  );

const sys = await feed(99);
log("system audio:", JSON.stringify({ ...sys, log: undefined }));
if (sys.unsupported) throw new Error("this browser has no WebCodecs AudioDecoder");
if (sys.system !== packets.length) throw new Error(`system counter ${sys.system} ≠ ${packets.length} packets handed to the decoder`);
if (sys.played < packets.length - 2) throw new Error(`only ${sys.played} of ${packets.length} packets produced a decoder output`);
if (sys.errors) throw new Error(`${sys.errors} play errors: ${sys.log.join(" | ")}`);
if (sys.rms < 0.1) throw new Error(`decoded audio is (near) silent: rms ${sys.rms}`);
if (engine === "chromium" && sys.ctx !== "running") throw new Error(`AudioContext is ${sys.ctx} after enable() — nothing would be heard`);

const voice = await feed(98);
log("voice:", JSON.stringify({ ...voice, log: undefined }));
if (voice.voice !== packets.length) throw new Error(`voice counter ${voice.voice} ≠ ${packets.length} (ssrc 0, pt 98, must decode like system audio)`);
if (voice.played < 2 * packets.length - 4) throw new Error(`voice packets did not reach the decoder output (${voice.played} total)`);
if (pageErrors.length) throw new Error("page errors: " + pageErrors.join(" | "));

log(`PASS — ${packets.length} Opus packets per type decoded and scheduled on ${engine}${channel && engine === "chromium" ? ` (${channel})` : ""}, peak rms ${sys.rms.toFixed(3)}, context ${sys.ctx}`);
await browser.close();
srv.close();
