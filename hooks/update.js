#!/usr/bin/env node
// Claude/Codex lifecycle hook -> ~/.claude/statusbar/state.d/<session_id>.json.

const fs = require("fs");
const os = require("os");
const path = require("path");
const cp = require("child_process");

const home = os.homedir();
const dir = path.join(home, ".claude", "statusbar");
const stateDir = path.join(dir, "state.d");
const indexPath = path.join(home, ".codex", "session_index.jsonl");
const quitMarker = path.join(dir, "quit-intent");
const event = process.argv[2] || "";

const TOOL_LABELS = {
  Bash: "Running command", Edit: "Editing", Write: "Writing", MultiEdit: "Editing",
  NotebookEdit: "Editing", Read: "Reading", Grep: "Searching", Glob: "Searching",
  WebFetch: "Browsing web", WebSearch: "Searching web", Task: "Delegating",
  TodoWrite: "Planning",
};

const safeId = (value) => String(value || "").replace(/[^A-Za-z0-9_.-]/g, "").slice(0, 64) || "unknown";

function codexThreadName(sessionId) {
  let newest = "";
  let name = "";
  try {
    for (const line of fs.readFileSync(indexPath, "utf8").split("\n")) {
      if (!line) continue;
      let row;
      try { row = JSON.parse(line); } catch { continue; }
      if (row.id !== sessionId || !row.thread_name) continue;
      const updated = String(row.updated_at || "");
      if (!name || updated >= newest) {
        newest = updated;
        name = row.thread_name;
      }
    }
  } catch {}
  return name;
}

function pidIsDead(pid) {
  if (!Number.isInteger(pid) || pid <= 0) return false;
  try { process.kill(pid, 0); return false; }
  catch (error) { return error && error.code === "ESRCH"; }
}

function pruneStale(now) {
  try {
    for (const file of fs.readdirSync(stateDir)) {
      if (!file.endsWith(".json")) continue;
      const fullPath = path.join(stateDir, file);
      let state;
      try { state = JSON.parse(fs.readFileSync(fullPath, "utf8")); } catch { continue; }
      const codexLike = !state.entrypoint && !state.term_program;
      const resting = !["permission", "thinking", "tool", "subagent"].includes(state.state);
      const staleCodex = codexLike && resting && now - Number(state.ts || 0) > 10 * 60;
      if (pidIsDead(Number(state.pid)) || staleCodex) fs.rmSync(fullPath, { force: true });
    }
  } catch {}
}

let raw = "";
process.stdin.on("data", (data) => (raw += data));
process.stdin.on("end", () => {
  let payload = {};
  try { payload = JSON.parse(raw || "{}"); } catch {}

  const sessionId = safeId(payload.session_id);
  const statePath = path.join(stateDir, sessionId + ".json");
  let previous = {};
  try { previous = JSON.parse(fs.readFileSync(statePath, "utf8")); } catch {}

  const cwd = payload.cwd || previous.cwd || "";
  const entrypoint = process.env.CLAUDE_CODE_ENTRYPOINT || previous.entrypoint || "";
  const termProgram = process.env.TERM_PROGRAM || previous.term_program || "";
  const codexLike = !entrypoint && !termProgram;
  const project = (codexLike ? codexThreadName(sessionId) : "")
    || (cwd ? path.basename(cwd) : previous.project || "");
  const now = Math.floor(Date.now() / 1000);
  let state = "idle";
  let label = "";
  let startedAt = previous.startedAt || 0;

  switch (event) {
    case "prompt": state = "thinking"; label = "Thinking…"; startedAt = now; break;
    case "pre":
      state = "tool";
      label = TOOL_LABELS[payload.tool_name || ""] || "Using tool";
      if (!startedAt) startedAt = now;
      break;
    case "post": state = "thinking"; label = "Thinking…"; if (!startedAt) startedAt = now; break;
    case "notify": {
      const message = String(payload.message || "").toLowerCase();
      const permission = payload.notification_type === "permission_prompt"
        || message.includes("permission") || message.includes("approve") || message.includes("allow");
      if (!permission) return;
      state = "permission"; label = "Awaiting permission"; startedAt = 0;
      break;
    }
    case "permreq": state = "permission"; label = "Awaiting permission"; startedAt = 0; break;
    case "stop": state = "done"; label = "Done"; startedAt = 0; break;
    default: return;
  }

  const output = {
    state, label, tool: payload.tool_name || "", project, cwd,
    sessionId: payload.session_id || "", transcript: payload.transcript_path || previous.transcript || "",
    entrypoint, term_program: termProgram, pid: process.ppid, started: true, startedAt, ts: now,
  };
  try {
    fs.mkdirSync(stateDir, { recursive: true });
    const temporary = statePath + "." + process.pid + ".tmp";
    fs.writeFileSync(temporary, JSON.stringify(output));
    fs.renameSync(temporary, statePath);
    pruneStale(now);
  } catch {}

  try {
    if (!fs.existsSync(quitMarker)) cp.execSync("pgrep -x CodexStatusBar", { stdio: "ignore" });
  } catch {
    try { cp.spawn("open", ["-g", "-b", "com.nickxma.codexstatusbar"], { stdio: "ignore", detached: true }).unref(); } catch {}
  }
});
