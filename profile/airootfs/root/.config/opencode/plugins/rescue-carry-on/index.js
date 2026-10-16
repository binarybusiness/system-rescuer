// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 Mikael Moghadam (Binary Business)
// rescue-carry-on: when the agent's turn ends before the rescue has
// its HANDBACK line in /root/rescue-log, prompt it to carry on. A model can
// end a turn on a plain "I'll start now" without calling a tool; nothing
// else would wake it, and the owner would wait on a silent screen.
//
// It nudges at most MAX_NUDGES times in a row while the log gains no lines,
// then stops and says so in the tmux status line, which tty1 and every SSH
// watcher see, until the session runs again. It stands down for good once
// the log has a HANDBACK line, or once someone other than rescue-agent and
// this plugin types a prompt: the owner is at the keyboard then. A question
// the agent asks with the question tool keeps its turn open, so it is never
// nudged while it waits for the owner's answer.
//
// OpenCode 2 has no session.idle event: a turn's end is
// session.execution.succeeded (after .failed, OpenCode retries by itself or
// rescue-agent restarts it). OpenCode may load the plugin once per location,
// and every instance sees every event, so each event is handled once, by its
// id, through module state shared on globalThis.
import { execFile } from "node:child_process"
import { readFileSync } from "node:fs"

const LOG = process.env.RESCUE_LOG ?? "/root/rescue-log"
const MAX_NUDGES = 3
const NUDGE = [
  "[rescue-carry-on] Your turn ended, but /root/rescue-log has no HANDBACK line yet, so the rescue is not finished",
  "and nobody is reading a plain message. Carry on with the next step of the method in AGENTS.md now, using your tools,",
  "within the guardrails, and log what you find and change. If a step needs the owner, ask with the question tool.",
  "If you cannot go further, write the HANDBACK line with the outcome that fits.",
].join(" ")
const GAVE_UP =
  " THE AGENT STOPPED before finishing (no HANDBACK). Type below what it should do next," +
  " or quit it (ctrl+c) and run rescue-agent to restart it. "

const state = (globalThis.__rescueCarryOn ??= { events: new Set(), sessions: new Map() })

function logState() {
  let text
  try {
    text = readFileSync(LOG, "utf8")
  } catch {
    return { lines: 0, handback: false }
  }
  return { lines: text.split("\n").filter(Boolean).length, handback: /\bHANDBACK\b/.test(text) }
}

function session(id) {
  let s = state.sessions.get(id)
  if (!s) state.sessions.set(id, (s = { prompts: 0, pending: 0, nudges: 0, lines: -1, done: false, stopped: false }))
  return s
}

// The tmux session's status line, when OpenCode runs inside tmux.
function statusLine(text) {
  if (!process.env.TMUX) return
  const args = text
    ? ["set", "-g", "status-left-length", "200", ";", "set", "-g", "status-style", "bg=red,fg=white", ";", "set", "-g", "status-left", text]
    : ["set", "-gu", "status-left-length", ";", "set", "-gu", "status-style", ";", "set", "-gu", "status-left"]
  execFile("tmux", args, () => {})
}

export default {
  id: "rescue-carry-on",
  setup(ctx) {
    const abort = new AbortController()
    ;(async () => {
      for await (const ev of ctx.event.subscribe({ signal: abort.signal })) {
        const id = ev.data?.sessionID
        if (!id || state.events.has(ev.id)) continue
        state.events.add(ev.id)
        const s = session(id)
        if (ev.type === "session.inbox.enqueued" && ev.data.item?.type === "user") {
          // The first prompt this process sees is rescue-agent's own; a
          // nudge is admitted before or after its prompt call returns.
          if (s.pending > 0) s.pending--
          else if (s.prompts > 0) s.done = true
          s.prompts++
        } else if (ev.type === "session.execution.started" && s.stopped) {
          s.stopped = false
          statusLine("")
        } else if (ev.type === "session.execution.succeeded" && !s.done) {
          const log = logState()
          if (log.handback) {
            s.done = true
            continue
          }
          if (log.lines !== s.lines) s.nudges = 0
          s.lines = log.lines
          if (s.nudges >= MAX_NUDGES) {
            s.done = s.stopped = true
            statusLine(GAVE_UP)
            continue
          }
          s.nudges++
          s.pending++
          await ctx.session.prompt({ sessionID: id, text: NUDGE }).catch(() => {
            s.pending--
          })
        }
      }
    })().catch(() => {})
    return () => abort.abort()
  },
}
