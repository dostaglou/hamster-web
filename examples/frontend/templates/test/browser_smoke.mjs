import { spawn } from "node:child_process";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
const profile = await mkdtemp(join(tmpdir(), "hamster-browser-"));
const browser = spawn(process.env.HAMSTER_BROWSER_BINARY, ["--headless=new", "--no-sandbox", "--disable-gpu", "--disable-background-networking", "--no-first-run", "--disable-sync", "--remote-debugging-port=0", `--user-data-dir=${profile}`], { detached: true, stdio: ["ignore", "ignore", "pipe"] });
let socket;
let logs = "";
try {
  const endpoint = await new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error("Browser startup timeout")), 10000);
    browser.stderr.on("data", bytes => {
      logs += bytes;
      const match = logs.match(/DevTools listening on (ws:\/\/[^\s]+)/);
      if (match) { clearTimeout(timer); resolve(match[1]); }
    });
    browser.on("error", reject);
    browser.on("exit", code => reject(new Error(`Browser exited ${code}: ${logs}`)));
  });
  socket = new WebSocket(endpoint);
  await new Promise((resolve, reject) => { socket.onopen = resolve; socket.onerror = reject; });
  let next = 1;
  const pending = new Map();
  socket.onmessage = event => {
    const message = JSON.parse(event.data);
    if (!message.id) return;
    const task = pending.get(message.id);
    if (!task) return;
    pending.delete(message.id);
    clearTimeout(task.timer);
    message.error ? task.reject(new Error(JSON.stringify(message.error))) : task.resolve(message.result);
  };
  const call = (method, params = {}, sessionId) => new Promise((resolve, reject) => {
    const id = next++;
    const timer = setTimeout(() => { pending.delete(id); reject(new Error(`${method} timeout`)); }, 5000);
    pending.set(id, { resolve, reject, timer });
    socket.send(JSON.stringify({ id, method, params, ...(sessionId ? { sessionId } : {}) }));
  });
  const { targetId } = await call("Target.createTarget", { url: "about:blank" });
  const { sessionId } = await call("Target.attachToTarget", { targetId, flatten: true });
  await call("Page.enable", {}, sessionId);
  await call("Page.navigate", { url: process.argv[2] }, sessionId);
  let result;
  for (let attempt = 0; attempt < 300; attempt++) {
    const state = await call("Runtime.evaluate", { expression: "JSON.stringify({result:document.body?.dataset.browserResult,error:document.body?.dataset.browserError})", returnByValue: true }, sessionId);
    result = JSON.parse(state.result.value || "{}");
    if (result.result) break;
    await new Promise(resolve => setTimeout(resolve, 100));
  }
  const page = await call("Runtime.evaluate", { expression: "document.documentElement.outerHTML", returnByValue: true }, sessionId);
  await writeFile(process.env.HAMSTER_BROWSER_ARTIFACT || join(tmpdir(), "hamster-browser-result.html"), page.result.value);
  if (result?.result !== "passed") throw new Error(`Stimulus/Turbo CRUD failed: ${JSON.stringify(result)}`);
  console.log("STIMULUS_TURBO_CRUD_OK");
} finally {
  socket?.close();
  try { process.kill(-browser.pid, "SIGTERM"); } catch {}
  await new Promise(resolve => { if (browser.exitCode !== null) return resolve(); const timer = setTimeout(() => { try { process.kill(-browser.pid, "SIGKILL"); } catch {} resolve(); }, 3000); browser.once("exit", () => { clearTimeout(timer); resolve(); }); });
  await rm(profile, { recursive: true, force: true });
}
