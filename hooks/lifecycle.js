#!/usr/bin/env node

const fs = require("fs");
const os = require("os");
const path = require("path");
const cp = require("child_process");

const dir = path.join(os.homedir(), ".claude", "statusbar");
const stateDir = path.join(dir, "state.d");
const event = process.argv[2] || "";
const safeId = (value) => String(value || "").replace(/[^A-Za-z0-9_.-]/g, "").slice(0, 64) || "unknown";

let raw = "";
let finished = false;
process.stdin.on("data", (data) => (raw += data));
process.stdin.on("end", run);
process.stdin.on("error", run);
setTimeout(run, 1000);

function run() {
  if (finished) return;
  finished = true;
  let payload = {};
  try { payload = JSON.parse(raw || "{}"); } catch {}
  const id = safeId(payload.session_id);
  const cwd = payload.cwd || "";
  const statePath = path.join(stateDir, id + ".json");
  fs.mkdirSync(stateDir, { recursive: true });

  if (event === "start") {
    try { fs.rmSync(path.join(dir, "quit-intent"), { force: true }); } catch {}
    const output = {
      state: "idle", label: "", tool: "", project: cwd ? path.basename(cwd) : "", cwd,
      sessionId: id, transcript: "", entrypoint: process.env.CLAUDE_CODE_ENTRYPOINT || "",
      term_program: process.env.TERM_PROGRAM || "", pid: process.ppid, started: false,
      startedAt: 0, ts: Math.floor(Date.now() / 1000),
    };
    try {
      const temporary = statePath + "." + process.pid + ".tmp";
      fs.writeFileSync(temporary, JSON.stringify(output));
      fs.renameSync(temporary, statePath);
    } catch {}
    try { cp.spawn("open", ["-g", "-b", "com.nickxma.codexstatusbar"], { stdio: "ignore", detached: true }).unref(); } catch {}
  } else if (event === "end") {
    try { fs.rmSync(statePath, { force: true }); } catch {}
  }
  process.exit(0);
}
