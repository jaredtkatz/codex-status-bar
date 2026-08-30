#!/usr/bin/env node

const assert = require("assert");
const fs = require("fs");
const os = require("os");
const path = require("path");
const cp = require("child_process");

const repo = path.resolve(__dirname, "..");
const home = fs.mkdtempSync(path.join(os.tmpdir(), "codex-statusbar-hooks-"));
try {
  const stateDir = path.join(home, ".claude", "statusbar", "state.d");
  const codexDir = path.join(home, ".codex");
  fs.mkdirSync(stateDir, { recursive: true });
  fs.mkdirSync(codexDir, { recursive: true });
  fs.writeFileSync(path.join(home, ".claude", "statusbar", "quit-intent"), "");

  const id = "01a053e7-b3a2-7de0-b64a-9afd2e474a4b";
  fs.writeFileSync(path.join(codexDir, "session_index.jsonl"), [
    JSON.stringify({ id, thread_name: "Old title", updated_at: "2026-08-30T10:00:00Z" }),
    JSON.stringify({ id, thread_name: "Newest exact title", updated_at: "2026-08-30T11:00:00Z" }),
  ].join("\n") + "\n");

  const old = Math.floor(Date.now() / 1000) - 601;
  fs.writeFileSync(path.join(stateDir, "stale-codex.json"), JSON.stringify({
    state: "idle", entrypoint: "", term_program: "", pid: 0, ts: old,
  }));
  fs.writeFileSync(path.join(stateDir, "dead-cli.json"), JSON.stringify({
    state: "done", entrypoint: "cli", term_program: "ghostty", pid: 99999999, ts: old,
  }));

  const env = { ...process.env, HOME: home };
  delete env.CLAUDE_CODE_ENTRYPOINT;
  delete env.TERM_PROGRAM;
  const result = cp.spawnSync(process.execPath, [path.join(repo, "hooks", "update.js"), "prompt"], {
    env, input: JSON.stringify({ session_id: id, cwd: "/tmp/fallback-folder" }), encoding: "utf8",
  });
  assert.strictEqual(result.status, 0, result.stderr);
  const current = JSON.parse(fs.readFileSync(path.join(stateDir, id + ".json"), "utf8"));
  assert.strictEqual(current.project, "Newest exact title");
  assert.strictEqual(current.state, "thinking");
  assert.strictEqual(current.entrypoint, "");
  assert.strictEqual(current.term_program, "");
  assert.strictEqual(fs.existsSync(path.join(stateDir, "stale-codex.json")), false);
  assert.strictEqual(fs.existsSync(path.join(stateDir, "dead-cli.json")), false);

  const settingsDir = path.join(home, ".claude");
  fs.writeFileSync(path.join(settingsDir, "settings.json"), JSON.stringify({
    hooks: { Stop: [{ hooks: [{ type: "command", command: "/usr/bin/keep-me" }] }] },
  }));
  const install = cp.spawnSync(process.execPath, [path.join(repo, "hooks", "install.js")], {
    env, encoding: "utf8",
  });
  assert.strictEqual(install.status, 0, install.stderr);
  const settings = JSON.parse(fs.readFileSync(path.join(settingsDir, "settings.json"), "utf8"));
  assert(settings.hooks.Stop.some((entry) => entry.hooks.some((hook) => hook.command === "/usr/bin/keep-me")));
  assert(settings.hooks.UserPromptSubmit.some((entry) => entry.hooks.some((hook) => hook.command.includes("statusbar/update.js"))));
  assert.strictEqual(
    fs.readFileSync(path.join(home, ".claude", "statusbar", "update.js"), "utf8"),
    fs.readFileSync(path.join(repo, "hooks", "update.js"), "utf8")
  );
  console.log("HookTests: passed");
} finally {
  fs.rmSync(home, { recursive: true, force: true });
}
