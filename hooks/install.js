#!/usr/bin/env node

const fs = require("fs");
const os = require("os");
const path = require("path");

const home = os.homedir();
const statusbarDir = path.join(home, ".claude", "statusbar");
const settingsPath = path.join(home, ".claude", "settings.json");
const updateDest = path.join(statusbarDir, "update.js");
const lifecycleDest = path.join(statusbarDir, "lifecycle.js");
const marker = statusbarDir;

fs.mkdirSync(statusbarDir, { recursive: true });
fs.copyFileSync(path.join(__dirname, "update.js"), updateDest);
fs.copyFileSync(path.join(__dirname, "lifecycle.js"), lifecycleDest);

let settings = {};
if (fs.existsSync(settingsPath)) {
  settings = JSON.parse(fs.readFileSync(settingsPath, "utf8"));
  const backup = settingsPath + ".bak-statusbar";
  if (!fs.existsSync(backup)) fs.copyFileSync(settingsPath, backup);
}
settings.hooks = settings.hooks || {};

const stripOurs = (entries) => (entries || [])
  .map((entry) => ({
    ...entry,
    hooks: (entry.hooks || []).filter((hook) => !String(hook.command || "").includes(marker)),
  }))
  .filter((entry) => entry.hooks.length > 0);

const add = (event, command, matcher) => {
  settings.hooks[event] = stripOurs(settings.hooks[event]);
  const entry = { hooks: [{ type: "command", command }] };
  if (matcher) entry.matcher = "*";
  settings.hooks[event].push(entry);
};
const command = (event) => `${process.execPath} ${JSON.stringify(updateDest)} ${event}`;
const lifecycle = (event) => `${process.execPath} ${JSON.stringify(lifecycleDest)} ${event}`;

add("UserPromptSubmit", command("prompt"), false);
add("PreToolUse", command("pre"), true);
add("PostToolUse", command("post"), true);
add("Notification", command("notify"), false);
add("PermissionRequest", command("permreq"), true);
add("Stop", command("stop"), false);
add("SessionStart", lifecycle("start"), false);
add("SessionEnd", lifecycle("end"), false);

fs.writeFileSync(settingsPath, JSON.stringify(settings, null, 2) + "\n");
