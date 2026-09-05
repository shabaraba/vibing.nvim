---
name: vibing-worker
description: Use when this chat's system prompt states it was started by another vibing.nvim chat (an orchestrator). Covers where and when to report back, the report's shape, and what not to do — the full version of the protocol summarized in that system-prompt line.
user-invocable: false
---

# vibing-worker

This chat is a worker: some other vibing.nvim chat (its orchestrator) created it and is waiting to
hear back. Your system prompt already names that chat and gives you the exact call to make — this
skill is the detail behind that line, not a replacement for it. If the two ever disagree, the
system-prompt line wins: it is generated fresh for this turn, this file can go stale.

## Where and how to report

Call `nvim_chat_send_message` with:

- `rpc_port`: this turn's value, exactly as given in your system prompt — required on every
  vibing-nvim MCP call, not just this one (see the `nvim-context` skill).
- `file_path`: the orchestrator's path, exactly as given in your system prompt. If your system
  prompt names more than one orchestrator, call this tool once per one — a single call reaches
  only the `file_path` it names.
- `from_bufnr`: your own chat buffer number, also given in your system prompt.
- `queue_if_busy: true`. Without it, the send is refused outright whenever the orchestrator
  happens to be mid-turn, and the report is simply lost — not retried, not queued.
- `message`: the report itself (shape below).

This is the only path that reaches the orchestrator. Writing your findings in your own chat
buffer and stopping does not report anything — nothing reads that buffer unless the orchestrator
calls `nvim_get_buffer` on it, which it only does after being told something is worth reading.

## When to report

**When the task is done.** The ordinary case: finish the work, then send the report before ending
your turn.

**Before you act on something you expect will need approval.** A tool-approval prompt kills your
turn on the spot — you cannot report _after_ hitting one, because there is no turn left to send
from. If you can see one coming (a destructive command, an edit outside what the brief covers),
send a heads-up first, in the same turn, before making that call. The orchestrator (or the user,
depending on `agent.orchestration.delegated_approval`) is who clears it either way; a heads-up
just means they aren't finding out from a cold watchdog notice with no context.

**The moment you find you cannot proceed.** Not "eventually, once you've tried everything" — as
soon as you know the task can't be finished as briefed (missing information, a conflicting
constraint, a brief that turns out to be ambiguous), report that and ask, rather than guessing or
grinding on it silently. A worker that stops normally after writing only "couldn't do this" in its
own buffer produces no notification at all: `idle` looks identical whether the task succeeded or
was abandoned halfway.

## Report shape

Conclusion → what changed → what's unresolved → what you need next. Briefly — the orchestrator can
read your transcript for detail it actually wants; a report that replays the working log is paid
for twice (once when you write it, once when it's read) for content that already sits in your
transcript for free.

- **Conclusion**: done, partially done, or blocked — one line.
- **What changed**: the files or state you touched, not how you got there.
- **What's unresolved**: anything left undone or uncertain.
- **What's needed next**: a decision, a missing input, or nothing (task fully closed).

## Do not

- **End your turn with only a prose report in your own chat buffer.** That is not a report; it is
  a transcript nobody was told to read. If you wrote something worth knowing, send it.
- **Edit `.claude/rules/**`** even if the task seems to call for it. Those files are this
  project's own invariants, kept deliberately small and reviewed as such — a worker changing them
  mid-task bypasses that review. Note the need in your report instead and let the orchestrator (or
  the user) decide.
- **Forward your own subagent- or worker-launch calls to the orchestrator as if they were your
  report.** If you dispatch a subagent or create worker chats of your own (see `vibing-orchestrate`
  for that case), "I launched X" is not an outcome — it tells the orchestrator what you did, not
  what happened. Wait for the outcome and report that, holding your own **completion** report
  until your own workers have reported back to you. That hold applies only to the completion
  report — a heads-up before an approval-prone action, or a report that you yourself are blocked,
  still goes out immediately under "When to report" above, whether or not your own workers have
  finished.
