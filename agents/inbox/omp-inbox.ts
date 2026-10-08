// Cross-session IRC for omp in herdr panes, and from easl tiles to herdr panes. omp's own IRC
// (`write agent://<id>`) only reaches agents in the same process; this extends it to every herdr
// agent, without adding tools:
// - Outbound: when a native `write agent://<name>` fails with "Unknown agent", deliver through
//   agent-msg instead (an easl tile's omp by its name or `name@board`, a herdr agent by name,
//   `<name>@<host>` on another machine over ssh) and report success. Reuse easl's message id
//   when its earlier attempt timed out: that prompt may still have reached the recipient.
// - Inbound (herdr panes only; tiles get easl's): messages land in this session's inbox and arrive
//   as one card per drain: easl's own `easl:message` custom message, drawn as omp draws its IRC
//   messages and recorded as a custom message, never as a user prompt, so transcripts and retros
//   tell them from Tim's prompts. They never touch the terminal, so they can't land in Tim's
//   half-typed draft or answer an open question. A message's file stays in the inbox until omp
//   records the card carrying it: nothing omp drops is lost.
// Delete this extension once every agent runs in an easl tile.
// @ts-nocheck

import { execFile } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const ROOT = path.join(os.homedir(), ".local/state/omp-inbox");
const SENDER = path.join(os.homedir(), ".local/bin/agent-msg");
const HOST = os.hostname().split(".")[0];
const PEER = /^agent:\/\/([A-Za-z0-9_.-]+)(?:@([A-Za-z0-9_.-]+))?\/?$/;
// easl's agent.prompt message id rule, shared with an earlier attempt at this write.
const MESSAGE_ID = /^msg_[A-Za-z0-9_-]{8,64}$/;
// Bounds a wake loop between two agents: past this many wakes per sender per hour, messages
// still arrive but wait for the recipient's next turn instead of starting one.
const WAKES_PER_HOUR = 20;
// easl's card type (easl `extensions/agent-hooks/messages.ts` EASL_MESSAGE, `card`), not omp's
// `irc:incoming`: omp's `wait` returns an `irc:incoming` from its queue as a bare text result, and
// one left over at a run's end wakes the agent even after Esc. Same `details` as easl's cards
// (`{id, from, message, ids}`), so a session resumed in an easl tile draws them with easl's renderer.
const EASL_MESSAGE = "easl:message";
// A card omp hasn't recorded this long after it went, with nothing streaming or queued, was
// dropped (Esc drops an agent's queued steer; a turn that couldn't start).
const RECORD_MS = 5_000;
// The `<` of an `irc` or `system-*` tag (omp's escapeHarnessTags) or of easl's guidance block.
const HARNESS_TAG = /<(?=\s*\/?\s*(?:irc|easl-guidance|system-[a-z][a-z-]*)(?![\w-]))/gi;
// Body rows a card shows folded and unfolded, and the widest a body row gets (omp's IRC card's).
const CARD_ROWS = { folded: 3, unfolded: 12 };
const CARD_ROW_COLUMNS = 100;

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

// One drain as one card: steered, starting a turn and recorded as a whole. The content, what the
// model reads, has each message in an IRC envelope as omp's own.
function card(messages) {
  return {
    customType: EASL_MESSAGE,
    content: messages.map(envelope).join("\n\n"),
    display: true,
    details: {
      id: messages[0].id,
      from: [...new Set(messages.map((message) => message.from))].join(", "),
      message: messages.map((message) => message.text).join("\n\n"),
      ids: messages.map((message) => message.id),
    },
    attribution: "agent",
  };
}

// The whole envelope body, sender and reply route included, is escaped once: only the outer
// `<irc>` tags are the extension's own.
function envelope({ from, text }): string {
  const said = `Message from \`${from}\`:\n\n${text}\n\nIf a response is expected, reply via \`write\` (\`path: "agent://${from}"\`, \`content: "…"\`).`;
  return `<irc>\n${said.replace(HARNESS_TAG, "&lt;")}\n</irc>`;
}

// A card as omp draws its own incoming IRC messages (pi-tui `createIrcMessageCard`, which omp
// doesn't export; a copy of easl's `renderCard`): `💬 IRC ← <from>` and the message's age, then its
// text quoted, three nonblank lines until unfolded (twelve then), each cut at 100 columns.
function renderCard(message, { expanded }, theme) {
  const from = message.details?.from?.trim() || "?";
  const rows = String(message.details?.message ?? "").split("\n").filter((line) => line.trim());
  const minutes = Math.floor((Date.now() - message.timestamp) / 60_000);
  const [hours, days] = [Math.floor(minutes / 60), Math.floor(minutes / 1440)];
  const age = days >= 30 ? `${Math.floor(days / 30)}mo ago` : days >= 7 ? `${Math.floor(days / 7)}w ago` : days ? `${days}d ago` : hours ? `${hours}h ago` : minutes ? `${minutes}m ago` : "just now";
  let drawn: { width: number; lines: string[] } | undefined;
  return {
    render(width: number): string[] {
      if (drawn?.width === width) return drawn.lines;
      // One column of padding each side, as omp's card.
      const inner = Math.max(1, width - 2);
      const glyph = theme.styledSymbol("tool.irc", "accent");
      const title = `IRC ${theme.nav.back} ${from}`;
      const room = inner - Bun.stringWidth(glyph) - 1;
      const meta = Bun.stringWidth(title) + 1 + Bun.stringWidth(age) <= room ? ` ${theme.fg("dim", age)}` : "";
      const quote = `  ${theme.fg("dim", theme.md.quoteBorder)} `;
      const columns = Math.min(CARD_ROW_COLUMNS, inner - Bun.stringWidth(quote));
      const shown = expanded ? CARD_ROWS.unfolded : CARD_ROWS.folded;
      const hidden = rows.length - shown;
      const lines = [
        `${glyph} ${theme.fg("accent", fit(title, room))}${meta}`,
        ...rows.slice(0, shown).map((row) => `${quote}${theme.fg("toolOutput", fit(row.trim().replaceAll("\t", "   "), columns))}`),
        ...(hidden > 0 ? [`${quote}${theme.fg("dim", fit(`… +${hidden} more ${hidden === 1 ? "line" : "lines"}`, columns))}`] : []),
      ];
      drawn = { width, lines: lines.map((line) => ` ${line} `) };
      return drawn.lines;
    },
    invalidate() {
      drawn = undefined;
    },
  };
}

// `text` cut to `columns` terminal columns with an ellipsis, at a character boundary.
function fit(text: string, columns: number): string {
  if (Bun.stringWidth(text) <= columns) return text;
  let kept = "";
  let used = 0;
  for (const { segment } of new Intl.Segmenter().segment(text)) {
    used += Bun.stringWidth(segment);
    if (used > columns - 1) break;
    kept += segment;
  }
  return columns > 0 ? `${kept}…` : "";
}

export default function (pi) {
  const inHerdr = process.env.HERDR_ENV === "1";
  if (!inHerdr && process.env.EASL_ENV !== "1") return;

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
    // A timed-out easl prompt may still queue. Every easl attempt at this write uses one id.
    const given = event.details?.easl?.message;
    const messageId = typeof given === "string" && MESSAGE_ID.test(given) ? given : `msg_${crypto.randomUUID().replaceAll("-", "")}`;
    const details = { ...event.details, easl: { ...event.details?.easl, message: messageId } };
    // From a tile, agent-msg names this tile by its easl address itself, and gets the address as
    // written: easl's extension can't read `name@<this host>` (it takes `@<host>` for a board).
    const args = inHerdr
      ? [target, text, "--from", await selfAddress(ctx)]
      : [host !== undefined ? `${name}@${host}` : name, text];
    args.push("--message", messageId);
    const sent = await run(SENDER, args);
    if (/agent-msg: (queued for|typed into)/.test(sent.out)) {
      // The IRC card renders from the native receipts, so mark them delivered too.
      const message = event.details?.message;
      const deliveredDetails = Array.isArray(message?.receipts)
        ? { ...details, message: { ...message, receipts: message.receipts.map((r) => ({ to: r.to, outcome: "injected" })) } }
        : details;
      return {
        isError: false,
        details: deliveredDetails,
        content: [{ type: "text", text: `Delivered to ${target}, an agent in another session. It arrives at that agent's next step; replies come back as messages from ${target}.` }],
      };
    }
    return {
      isError: true,
      details,
      content: [{ type: "text", text: `${native}\nNo cross-session delivery to ${target}: ${sent.out || "no response"}` }],
    };
  });

  let dir: string | undefined;
  let watcher: fs.FSWatcher | undefined;
  // The bound root session's context: whether omp streams, what it has queued, its UI.
  let session;
  // Messages handed to omp and not recorded yet, by id (their file's name without `.json`), with
  // when they went.
  const handed = new Map<string, number>();
  // Messages that wait for the next turn that starts: past the wake bound, or dropped unrecorded
  // (`unrecorded`). They stay out of omp's own next-turn queue, which agent-started turns skip
  // and a cancelled prompt empties without recording.
  const nextStart = new Set<string>();
  let recordCheck;

  // The inbox's messages not handed to omp yet, oldest first. A file that isn't a message goes.
  function waiting(): { id: string; from: string; text: string }[] {
    let names: string[];
    try {
      names = fs.readdirSync(dir).filter((name) => name.endsWith(".json")).sort();
    } catch {
      return [];
    }
    const messages = [];
    for (const name of names) {
      const id = name.slice(0, -".json".length);
      if (handed.has(id)) continue;
      const file = path.join(dir, name);
      let message;
      try {
        message = JSON.parse(fs.readFileSync(file, "utf8"));
      } catch (error) {
        if (error?.code === "ENOENT") continue;
      }
      const text = typeof message?.text === "string" ? message.text.trim() : "";
      if (!text) {
        try {
          fs.unlinkSync(file);
        } catch {}
        continue;
      }
      const from = typeof message.from === "string" && message.from ? message.from : "an agent";
      messages.push({ id, from, text });
    }
    return messages;
  }

  function drain() {
    if (!dir || !session) return;
    // Coalesce everything waiting into one card: one wake, not one per message.
    const messages = waiting().filter((message) => !nextStart.has(message.id));
    if (messages.length === 0) return;
    const now = Date.now();
    let overBudget = false;
    for (const from of new Set(messages.map((message) => message.from))) {
      const recent = (wakes.get(from) ?? []).filter((at) => now - at < 3_600_000);
      overBudget ||= recent.length >= WAKES_PER_HOUR;
      recent.push(now);
      wakes.set(from, recent);
    }
    if (overBudget) {
      for (const message of messages) nextStart.add(message.id);
      return;
    }
    send(messages, "now");
  }

  // `now`: a steer while omp streams (it joins the turn at the next step, cutting a `wait` short),
  // else a new turn (`triggerTurn`: an idle custom steer without it is only appended). `aside`:
  // joins the turn that just started without interrupting it.
  function send(messages, how: "now" | "aside") {
    pi.sendMessage(card(messages), how === "aside" ? { deliverAs: "aside" } : { deliverAs: "steer", triggerTurn: true });
    const at = Date.now();
    for (const message of messages) handed.set(message.id, at);
    recordCheck ??= setTimeout(unrecorded, RECORD_MS);
  }

  // omp recorded it: its file goes.
  function acked(id: string) {
    handed.delete(id);
    try {
      fs.unlinkSync(path.join(dir, `${id}.json`));
    } catch {}
  }

  // A card omp never recorded (Esc drops an agent's queued steer; a turn it couldn't start, as
  // with no model): once nothing streams or waits in omp's queues, its messages ride the next turn
  // that starts, and Tim is told.
  function unrecorded() {
    recordCheck = undefined;
    if (!session) return;
    if (session.isIdle() && !session.hasPendingMessages()) {
      const due = Date.now() - RECORD_MS;
      const lost = [...handed].filter(([, at]) => at <= due).map(([id]) => id);
      for (const id of lost) {
        handed.delete(id);
        nextStart.add(id);
      }
      if (lost.length > 0) {
        const what = lost.length === 1 ? "a message" : `${lost.length} messages`;
        session.ui.notify(`omp-inbox: omp started no turn with ${what}; ${lost.length === 1 ? "it rides" : "they ride"} the next turn that starts`, "warning");
      }
    }
    if (handed.size > 0) recordCheck = setTimeout(unrecorded, RECORD_MS);
  }

  function unbind() {
    watcher?.close();
    watcher = undefined;
    clearTimeout(recordCheck);
    recordCheck = undefined;
    handed.clear();
    nextStart.clear();
    if (dir) {
      try {
        if (fs.readFileSync(path.join(dir, ".pid"), "utf8") === String(process.pid)) {
          fs.unlinkSync(path.join(dir, ".pid"));
        }
      } catch {}
    }
    dir = undefined;
    session = undefined;
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
    session = ctx;
    watcher = fs.watch(dir, () => drain());
    drain();
  }

  if (!inHerdr) return;
  pi.registerMessageRenderer(EASL_MESSAGE, renderCard);
  pi.on("session_start", (_event, ctx) => bind(ctx));
  pi.on("session_switch", (_event, ctx) => bind(ctx));
  pi.on("session_shutdown", () => unbind());
  // omp recorded a card: the messages it carries are delivered.
  pi.on("message_end", (event) => {
    const message = event.message;
    if (handed.size === 0 || message?.role !== "custom" || message.customType !== EASL_MESSAGE) return;
    for (const id of message.details?.ids ?? []) if (handed.has(id)) acked(id);
  });
  // Messages waiting for a turn ride the one that starts, without interrupting it.
  pi.on("agent_start", () => {
    if (nextStart.size === 0 || !dir) return;
    const riding = waiting().filter((message) => nextStart.has(message.id));
    nextStart.clear();
    if (riding.length > 0) send(riding, "aside");
  });
}
