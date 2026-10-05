// Delivers messages from other agents into this omp session without touching the terminal.
// Senders run `agent-msg <agent> <text>`, which drops a JSON file into this session's inbox.
// Each message arrives as an agent-attributed aside at the next step boundary, so it never
// lands in Tim's half-typed draft, never answers an open question, and never stops a run.
// @ts-nocheck

import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const ROOT = path.join(os.homedir(), ".local/state/omp-inbox");

// Same key agent-msg derives from `herdr agent get`: the session file's name, else its id.
function inboxKey(ctx): string | undefined {
  try {
    const file = ctx?.sessionManager?.getSessionFile?.();
    if (typeof file === "string" && file.length > 0) return path.basename(file, ".jsonl");
    const id = ctx?.sessionManager?.getSessionId?.();
    if (typeof id === "string" && id.length > 0) return id;
  } catch {}
  return undefined;
}

export default function (pi) {
  if (process.env.HERDR_ENV !== "1") return;

  let dir: string | undefined;
  let watcher: fs.FSWatcher | undefined;

  function drain() {
    if (!dir) return;
    let names: string[];
    try {
      names = fs.readdirSync(dir).filter((name) => name.endsWith(".json")).sort();
    } catch {
      return;
    }
    for (const name of names) {
      const file = path.join(dir, name);
      let message;
      try {
        message = JSON.parse(fs.readFileSync(file, "utf8"));
        fs.unlinkSync(file);
      } catch {
        continue;
      }
      const text = typeof message?.text === "string" ? message.text.trim() : "";
      if (!text) continue;
      const from = typeof message.from === "string" && message.from ? message.from : "another agent";
      pi.sendUserMessage(`[message from ${from} via agent-msg]\n${text}`, {
        deliverAs: "aside",
        attribution: "agent",
      });
    }
  }

  function unbind() {
    watcher?.close();
    watcher = undefined;
    if (dir) {
      try {
        if (fs.readFileSync(path.join(dir, ".pid"), "utf8") === String(process.pid)) {
          fs.unlinkSync(path.join(dir, ".pid"));
        }
      } catch {}
    }
    dir = undefined;
  }

  // Only the pane's root session gets an inbox; subagents have no UI.
  function bind(ctx) {
    if (ctx?.hasUI !== true) return;
    const key = inboxKey(ctx);
    if (!key) return;
    const next = path.join(ROOT, key);
    if (next === dir) return;
    unbind();
    fs.mkdirSync(next, { recursive: true, mode: 0o700 });
    fs.writeFileSync(path.join(next, ".pid"), String(process.pid));
    dir = next;
    watcher = fs.watch(dir, () => drain());
    drain();
  }

  pi.on("session_start", (_event, ctx) => bind(ctx));
  pi.on("session_switch", (_event, ctx) => bind(ctx));
  pi.on("session_shutdown", () => unbind());
}
