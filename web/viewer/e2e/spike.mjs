// Phase 2 gate (plans/browser-viewer.md): bytes flow browser ↔ sharer through
// the guest tunnel, with the sharer being the REAL Linux sharer in link-only
// mode and the browser being real Chromium. No internet: a local DERP stands
// in for the relay fleet.
//
//   localderp ──DERP/WebSocket──▶ Chromium page (wasm: guest client + sdk/go)
//       ▲                              │ framed mediaDatagram HELLO
//       └──────DERP/TLS──── tailscreen-sharer-linux --link (Xvfb capture)
//
// Asserts: the page reaches `acked` (HELLO → auto-approved → HELLO_ACK, all as
// frames — the stream profile end to end), then that video RTP arrives over
// the stream and — where the browser can decode H.264 — that frames are
// decoded and something non-uniform is painted on the canvas. Prints the
// wasm sizes at the end.
//
// Playwright's own Chromium ships without the proprietary codecs, so H.264
// via WebCodecs is `supported: false` there; Google Chrome (`playwright
// install chrome`, `channel: "chrome"`) decodes it. The harness prefers
// Chrome when present (PW_CHANNEL overrides) and degrades to the transport
// assertions plus the page's own "cannot decode" placard otherwise.
//
// Run via `make test-web-spike` (which sets NODE_PATH for the global
// playwright module and builds everything this needs).

import { spawn, execFileSync } from "node:child_process";
import { createRequire } from "node:module";
import { createServer } from "node:http";
import { readFile, stat } from "node:fs/promises";
import { statSync, existsSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const require = createRequire(import.meta.url);
const { chromium } = require(process.env.PLAYWRIGHT_MODULE ?? "playwright");

const here = path.dirname(fileURLToPath(import.meta.url));
const viewerDir = path.resolve(here, "..");
const repoRoot = path.resolve(viewerDir, "../..");
const sharerBin =
  process.env.TAILSCREEN_SHARER_BIN ??
  path.join(repoRoot, "Packages/TailscreenLinuxBackends/.build/debug/tailscreen-sharer-linux");
const localderpBin = path.join(viewerDir, "dist/localderp");
const display = process.env.TAILSCREEN_E2E_DISPLAY ?? ":99";
const fps = process.env.TAILSCREEN_E2E_FPS ?? "10";
const wantVideo = Number(process.env.TAILSCREEN_E2E_MIN_VIDEO ?? 50);
const wantFrames = Number(process.env.TAILSCREEN_E2E_MIN_FRAMES ?? 10);
const channel = process.env.PW_CHANNEL ?? (existsSync("/opt/google/chrome/chrome") ? "chrome" : undefined);

const children = [];
const log = (...a) => console.log("[spike]", ...a);
function run(name, cmd, args, opts = {}) {
  const child = spawn(cmd, args, { stdio: ["ignore", "pipe", "pipe"], ...opts });
  child.stdout.on("data", (d) => process.stdout.write(`[${name}] ${d}`));
  child.stderr.on("data", (d) => process.stderr.write(`[${name}] ${d}`));
  child.on("error", (e) => log(`${name} could not start: ${e.message}`));
  child.on("exit", (code, sig) => log(`${name} exited (${code ?? sig})`));
  children.push(child);
  return child;
}
function waitForLine(child, re, timeoutMs, name) {
  return new Promise((resolve, reject) => {
    let buf = "";
    const timer = setTimeout(() => reject(new Error(`${name}: no match for ${re} within ${timeoutMs} ms`)), timeoutMs);
    const onData = (d) => {
      buf += d.toString();
      const m = buf.match(re);
      if (m) {
        clearTimeout(timer);
        resolve(m);
      }
    };
    child.stdout.on("data", onData);
    child.stderr.on("data", onData);
    child.on("exit", (code) => {
      clearTimeout(timer);
      reject(new Error(`${name} exited (${code}) before printing ${re}`));
    });
  });
}
function cleanup() {
  for (const c of children.reverse()) {
    try {
      c.kill("SIGTERM");
    } catch {}
  }
}
process.on("exit", cleanup);
for (const sig of ["SIGINT", "SIGTERM"]) process.on(sig, () => process.exit(130));

const mime = { ".html": "text/html", ".js": "text/javascript", ".wasm": "application/wasm" };
function serveStatic(dir) {
  return new Promise((resolve) => {
    const srv = createServer(async (req, res) => {
      const rel = decodeURIComponent(new URL(req.url, "http://x").pathname);
      const file = path.join(dir, rel === "/" ? "index.html" : rel);
      if (!file.startsWith(dir)) return res.writeHead(403).end();
      try {
        await stat(file);
        res.writeHead(200, { "Content-Type": mime[path.extname(file)] ?? "application/octet-stream" });
        res.end(await readFile(file));
      } catch {
        res.writeHead(404).end();
      }
    });
    srv.listen(0, "127.0.0.1", () => resolve({ srv, port: srv.address().port }));
  });
}

async function main() {
  for (const bin of [sharerBin, localderpBin]) {
    if (!existsSync(bin)) throw new Error(`missing ${bin} (run \`make test-web-spike\`, which builds it)`);
  }
  if (!existsSync(path.join(viewerDir, "dist/viewer.wasm"))) throw new Error("missing dist/viewer.wasm (make web-viewer)");

  // 1. The relay.
  const derp = run("localderp", localderpBin, ["-host", "127.0.0.1"]);
  const derpLine = await waitForLine(derp, /LOCALDERP derpmap=(\S+)/, 15_000, "localderp");
  const derpMapURL = derpLine[1];
  log("relay up, derpmap", derpMapURL);

  // 2. A display with something on it.
  run("xvfb", "Xvfb", [display, "-screen", "0", "1280x720x24"]);
  await new Promise((r) => setTimeout(r, 1500));
  try {
    const png = "/tmp/tailscreen-spike-pattern.png";
    execFileSync("convert", ["-size", "1280x720", "gradient:red-blue", png]);
    run("display", "display", ["-immutable", "-geometry", "+0+0", png], { env: { ...process.env, DISPLAY: display } });
    await new Promise((r) => setTimeout(r, 1000));
  } catch {
    log("ImageMagick absent — capturing a blank root");
  }

  // 3. The real sharer, link-only, approving guests as they park.
  const sharer = run(
    "sharer",
    sharerBin,
    ["--link", "--link-relay-map-url", derpMapURL, "--approve-guests", "--fps", fps, "--display", display],
    { env: { ...process.env, DISPLAY: display } },
  );
  const tokenLine = await waitForLine(sharer, /E2E_MARKER shareLink token=(tc\S+)/, 90_000, "sharer");
  const token = tokenLine[1];
  log("share link minted", token.slice(0, 16) + "…");

  // 4. The page, served like a static site would.
  const { srv, port } = await serveStatic(viewerDir);
  const url = `http://127.0.0.1:${port}/index.html#${token}`;

  // 5. The browser. ignoreHTTPSErrors covers the relay's self-signed
  // certificate on the wss:// connection (the native side skips verification
  // via the node's InsecureForTests flag). --no-proxy-server: a CI or sandbox
  // container often exports HTTP(S)_PROXY, which Chromium would honour for the
  // wss:// relay dial too; nothing here leaves the loopback interface.
  log(`launching ${channel ?? "playwright chromium"}`);
  const browser = await chromium.launch({ headless: true, channel, args: ["--no-proxy-server"] });
  const context = await browser.newContext({ ignoreHTTPSErrors: true });
  const page = await context.newPage();
  page.on("console", (m) => log("page:", m.text()));
  page.on("pageerror", (e) => log("page error:", e.message));
  await page.goto(url);

  const state = () => page.evaluate(() => JSON.parse(JSON.stringify(window.__viewer)));
  await page.waitForFunction(
    () => ["acked", "denied", "error", "ended", "closed"].includes(window.__viewer?.state),
    null,
    { timeout: 120_000 },
  );
  let s = await state();
  if (s.state !== "acked") throw new Error(`page ended in state ${s.state}: ${s.lastError ?? ""}\n${s.log.join("\n")}`);
  log(`admitted over the stream: ssrc=${s.ssrc}, server ${s.serverAddr}`);

  await page.waitForFunction((n) => window.__viewer.rtpVideo >= n, wantVideo, { timeout: 60_000 });
  const canDecode = await page.evaluate(() =>
    VideoDecoder.isConfigSupported({ codec: "avc1.42E01E" }).then((r) => r.supported).catch(() => false),
  );
  if (canDecode) {
    await page.waitForFunction((n) => window.__viewer.decodedFrames >= n, wantFrames, { timeout: 60_000 });
    await new Promise((r) => setTimeout(r, 1500));
    s = await state();
    // Real pixels, not a flat rectangle: sample the canvas and demand spread.
    const spread = await page.evaluate(() => {
      const c = document.getElementById("stage");
      const d = c.getContext("2d").getImageData(0, 0, c.width, c.height).data;
      const lumas = [];
      for (let i = 0; i < 400; i++) {
        const px = Math.floor(((i * 7919) % (c.width * c.height))) * 4;
        lumas.push(0.299 * d[px] + 0.587 * d[px + 1] + 0.114 * d[px + 2]);
      }
      const mean = lumas.reduce((a, b) => a + b, 0) / lumas.length;
      return Math.sqrt(lumas.reduce((a, b) => a + (b - mean) ** 2, 0) / lumas.length);
    });
    log(
      `decoded ${s.decodedFrames} frames (${s.codecString}, ${s.width}×${s.height}, ${s.fps} fps, ${s.kbps} kbps); ` +
        `AUs ${s.videoAUs}, dropped ${s.droppedAUs}, errors ${s.decodeErrors}; canvas luma spread ${spread.toFixed(1)}`,
    );
    if (s.decodeErrors > 0) throw new Error(`${s.decodeErrors} decode errors`);
    if (!(spread > 8)) throw new Error(`canvas looks flat (luma spread ${spread.toFixed(1)}) — capture produced no content?`);
  } else {
    await page.waitForFunction(() => window.__viewer.state === "unsupported" || window.__viewer.videoAUs >= 5, null, {
      timeout: 60_000,
    });
    s = await state();
    log(`NOTE: this browser cannot decode H.264 (Playwright's Chromium?) — transport verified only: ` +
        `${s.rtpVideo} video datagrams, ${s.videoAUs} access units assembled, state ${s.state}`);
  }
  if (s.lastError) throw new Error(s.lastError);

  const sizes = ["viewer.wasm", "viewer.wasm.gz", "viewer.wasm.br"]
    .map((f) => path.join(viewerDir, "dist", f))
    .filter(existsSync)
    .map((f) => `${path.basename(f)}=${(statSync(f).size / 1e6).toFixed(2)}MB`);
  log("PASS —", sizes.join(" "));

  await browser.close();
  srv.close();
}

main().then(
  () => process.exit(0),
  (err) => {
    console.error("[spike] FAIL", err?.stack ?? err);
    process.exit(1);
  },
);
