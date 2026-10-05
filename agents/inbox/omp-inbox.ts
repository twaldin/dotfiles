// Cross-session IRC for omp in herdr panes. omp's own IRC (`write agent://<id>`) only reaches
// agents in the same process. This extension extends it to every herdr agent, without adding tools:
// - Outbound: when a native `write agent://<name>` fails with "Unknown agent", deliver to the herdr
//   agent of that name instead (`<name>@<host>` reaches another machine over ssh) and report success.
// - Inbound: messages land in this session's inbox and arrive as one agent-attributed aside at the
//   next step boundary. They never touch the terminal, so they can't land in Tim's half-typed draft,
//   answer an open question or stop a run.
// Delete this extension once omp ships cross-session hub messaging (can1357/oh-my-pi#7537).
// @ts-nocheck

import { execFile } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const ROOT = path.join(os.homedir(), ".local/state/omp-inbox");
const SENDER = path.join(os.homedir(), ".local/bin/agent-msg");
const HOST = os.hostname().split(".")[0];
const PEER = /^agent:\/\/([A-Za-z0-9_.-]+)(?:@([A-Za-z0-9_.-]+))?\/?$/;
// Bounds a wake loop between two agents: past this many wakes per sender per hour, messages
// still arrive but wait for the recipient's next turn instead of starting one.
const WAKES_PER_HOUR = 20;

function run(command: string, args: string[]): Promise<{ code: number; out: string }> {
  const { promise, resolve } = Promise.withResolvers<{ code: number; out: string }>();
  execFile(command, args, { timeout: 20_000 }, (error, stdout, stderr) => {
    const code = error ? (typeof error.code === "number" ? error.code : 1) : 0;
    resolve({ code, out: `${stdout}${stderr}`.trim() });
  });
  return promise;
}

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

  const wakes = new Map<string, number[]>();

  // This session's address for replies: its herdr agent name, matched by session file.
  async function selfAddress(ctx): Promise<string> {
    const file = ctx?.sessionManager?.getSessionFile?.();
    const listed = await run("herdr", ["agent", "list"]);
    try {
      for (const agent of JSON.parse(listed.out).result.agents) {
        if (agent.name && agent.agent_session?.value === file) return `${agent.name}@${HOST}`;
      }
    } catch {}
    return `${ctx?.agent?.name ?? "agent"}@${HOST}`;
  }

  pi.on("tool_result", async (event, ctx) => {
    if (event.toolName !== "write" || !event.isError) return;
    const match = PEER.exec(String(event.input?.path ?? ""));
    const text = typeof event.input?.content === "string" ? event.input.content.trim() : "";
    if (!match || !text || match[1] === "all") return;
    const native = (event.content ?? []).map((part) => part.text ?? "").join("\n");
    if (!native.includes("Unknown agent")) return;
    const [, name, host] = match;
    const target = host !== undefined && host !== HOST ? `${name}@${host}` : name;
    const sent = await run(SENDER, [target, text, "--from", await selfAddress(ctx)]);
    if (/agent-msg: (queued for|typed into)/.test(sent.out)) {
      // The IRC card renders from the native receipts, so mark them delivered too.
      const message = event.details?.message;
      const details = Array.isArray(message?.receipts)
        ? { ...event.details, message: { ...message, receipts: message.receipts.map((r) => ({ to: r.to, outcome: "injected" })) } }
        : event.details;
      return {
        isError: false,
        details,
        content: [{ type: "text", text: `Delivered to ${target}, an agent in another session. It arrives at that agent's next step; replies come back as messages from ${target}.` }],
      };
    }
    return { content: [{ type: "text", text: `${native}\nNo cross-session delivery to ${target}: ${sent.out || "no response"}` }] };
  });

  let dir: string | undefined;
  let watcher: fs.FSWatcher | undefined;
  let busy = false;
  pi.on("agent_start", () => {
    busy = true;
  });
  pi.on("agent_end", () => {
    busy = false;
  });

  function drain() {
    if (!dir) return;
    let names: string[];
    try {
      names = fs.readdirSync(dir).filter((name) => name.endsWith(".json")).sort();
    } catch {
      return;
    }
    // Coalesce everything waiting into one delivery: one wake, not one per message.
    const parts: string[] = [];
    const senders = new Set<string>();
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
      const from = typeof message.from === "string" && message.from ? message.from : "an agent";
      senders.add(from);
      parts.push(`[message from ${from}; reply with write agent://${from}]\n${text}`);
    }
    if (parts.length === 0) return;
    const now = Date.now();
    let overBudget = false;
    for (const from of senders) {
      const recent = (wakes.get(from) ?? []).filter((at) => now - at < 3_600_000);
      overBudget ||= recent.length >= WAKES_PER_HOUR;
      recent.push(now);
      wakes.set(from, recent);
    }
    // Busy: a steer, which also interrupts a long `wait` (an aside would sit until it returned).
    // Idle: an aside, which starts a turn and leaves Tim's half-typed draft alone.
    pi.sendUserMessage(parts.join("\n\n"), {
      deliverAs: overBudget ? "nextTurn" : busy ? "steer" : "aside",
      attribution: "agent",
    });
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
