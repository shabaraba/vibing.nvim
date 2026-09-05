---
name: vibing-orchestrate
description: Run several independent tasks in parallel by creating worker vibing.nvim chats, handing each one a self-contained brief, and aggregating their results. Use when the user asks for parallel work ("do these three in parallel", "split this across separate chats", "並行でやって", "この2つを別々のチャットで").
---

# vibing-orchestrate

This chat becomes the orchestrator: it splits the work, creates one worker chat per task, sends
each worker a brief, and later reports back. It does **not** babysit the workers — see "Hand
control back" below, which is the part that most needs following.

Every MCP call here takes `rpc_port`, the value in this chat's system prompt. Without it the
server falls back to the instance registry, which only answers when exactly one Neovim is live —
and orchestration is precisely the case where several are.

## Chat or subagent?

A chat is a unit of **ownership**; a subagent is a unit of **delegated work inside one turn**. The
most expensive mistake a postmortem (#692) found was broadcasting `/simplify` to five worker
chats — each spawns its own subagents, so that's the chat count times the subagent count, and it
was one of two runs that hit the session limit. Decide this before creating anything.

|                        | Subagent                                         | Orchestrated chat                                   |
| ---------------------- | ------------------------------------------------ | --------------------------------------------------- |
| Lifetime               | Dies with the parent turn                        | Survives restarts                                   |
| Output                 | One final text blob                              | Its own transcript                                  |
| Visibility             | None                                             | Buffer can be opened and read, mid-task             |
| Approval prompts       | Can't clear one (turn just fails)                | Can handle questions and approvals                  |
| Owns a branch/worktree | No                                               | Yes, via `working_dir` frontmatter                  |
| Survives a rate limit  | No                                               | Yes (auto_resume / scheduled resend)                |
| Spin-up cost           | Low, no protocol                                 | Floor ~61k tokens + report contract + notifications |
| Coordination can fail  | No — the return value is structurally guaranteed | Yes — this run failed 9 of 18 dispatches            |

**A subagent is enough only if all five hold** — one exception and it's a chat:

1. It finishes in one round trip, with a definable output, no mid-task change of direction
2. Nobody needs to watch it run
3. It doesn't own a branch or worktree — it stays inside the parent's own working tree
4. It's unlikely to hit an approval prompt (read-heavy, or the parent's session permissions cover it)
5. You would not want to reread its transcript tomorrow

**Use a chat if any one of these holds:** it spans multiple turns (implement → wait on CI → address
review → fix → merge); it owns a branch/worktree a later turn still needs; it will hit an approval
prompt only a human should clear; a human wants to open it mid-task and steer it; it might need
re-briefing after a partial failure; it has to survive a rate limit; or its transcript is itself the
record you'll want later.

**General rule: parallelism inside work that already has a chat belongs to subagents. Don't add
chats to get parallelism** — a chat's floor is ownership, not concurrency.

## Operator rules

- **Don't write the report protocol into a brief.** Creating a worker with `from_bufnr` is enough —
  the plugin injects it from `orchestrated_by` every turn (#706). Keep the brief to the task itself.
- **Don't broadcast a subagent-spawning command** (`/simplify`, `/code-review`, …) **to more than one
  worker at a time.** Each broadcast multiplies concurrency by that command's own subagent count.
- **Parallelize the implementation step; serialize anything that touches `main`** (merges, cleanup).
- **Write the assignment table (who owns what) to a file**, not only into your own context — it has
  to survive a restart or compaction.
- **Don't take a review finding at face value.** Verify before acting on it; a finding can itself be
  wrong.

## Environment notes

- **macOS's `nc` cannot hold a conversation with this RPC server.** It closes on stdin EOF before the
  response comes back over `vim.schedule`. Use Python's `socket.create_connection(...)` with
  `makefile("rwb")` instead if you need to talk to it directly.
- **Claude Code's built-in sensitive-file guard refuses `Edit`/`Write` on `.claude/rules/**`,**
  independent of this project's own permission rules. Don't brief a worker to edit rules files —
  either do it yourself as the orchestrator, or write the brief assuming a human will clear it.

## 1. Split the work

Break the request into tasks that can run without waiting on each other. If two tasks would edit
the same files, either merge them into one task or give each its own worktree with the
`vibing-worktree-create` skill (`git worktree add -b <branch> .vibing/worktrees/<branch>`) — two
chats editing one working tree will overwrite each other, and nothing in vibing.nvim prevents it.

Separate worktrees stop the overwriting, not the overlap: two branches can still change the same
file in ways that only collide at merge time. Once workers are running, call
`nvim_chat_conflicts({ rpc_port })` — it diffs every live chat's `working_dir` worktree against
`main` and names the files two or more of them touch. It warns, it does not block; call it before
you merge anything, and read the overlapping files in both branches yourself.

If the split isn't obvious, ask with `nvim_ask_user_question` before creating anything. Creating
five chats for a job that was really one is expensive and the user has to clean them up.

## 2. Create one worker chat per task

```text
nvim_chat_create({ rpc_port, position: "back", from_bufnr: <this chat's bufnr> })
nvim_chat_create({
  rpc_port,
  position: "back",
  from_bufnr: <this chat's bufnr>,
  working_dir: ".vibing/worktrees/fix-auth",
})
```

- `position: "back"` (the default) creates the buffer without opening a window, so the user's
  layout is untouched. Don't use a split position for workers unless the user asked to watch them.
- `working_dir` is relative to the git root and must already exist — create the worktree first.
- **Always pass `from_bufnr`**: the exact "Current vibing.nvim chat buffer number" from your
  system prompt. It records the relationship in both chat files' frontmatter (`orchestrated` here,
  `orchestrated_by` on the worker), which is what makes it survive a rename or a restart.
- Keep the returned `file_path` **and** `bufnr` for every worker, and write them into your reply
  in this chat. `from_bufnr` records the relationship, but not which worker owns which task — that
  mapping only exists in what you write here, and the transcript is where you read it back from if
  the conversation is resumed later.
- **Address a worker by `file_path`, not `bufnr`.** Both `nvim_chat_send_message` and
  `nvim_get_buffer` take either, but a buffer number only means something in the Neovim session
  that issued it — after a restart the same number points at some unrelated buffer, so a
  conversation resumed the next morning would drive the wrong buffer. The path keeps working, and
  a worker chat that is no longer open is opened for you. Pass one or the other; passing both is
  an error.
- If `agent.orchestration.delegated_approval` is `"scoped"`, declare what this worker may need
  approved up front with `delegated_scope` (same pattern syntax as `permissions_allow`, e.g.
  `delegated_scope: ["Bash(npm:*)"]`). It is written on the worker's own frontmatter, and is what
  makes "Answering a worker's tool approval" below a safe machine check instead of a judgment call
  each time. Skip it under `true` (everything is already delegated) or `false` (nothing is).

## 3. Send each worker a self-contained brief

```text
nvim_chat_send_message({
  rpc_port,
  file_path: "<worker file_path>",
  from_bufnr: <this chat's bufnr>,
  message: "<the whole task>",
})
```

Pass `from_bufnr` here too. It is the same value as in step 2, and sending is what registers the
relationship for a worker you did not create yourself.

A worker chat starts empty. It has none of this conversation's context: not the user's original
request, not the files already discussed, not the decisions already made. Write the brief as if to
someone who just walked in — goal, the files or directories involved, the constraints, and what
"done" looks like. A brief that says "do the refactor we discussed" produces nothing useful.

### The brief does not need to teach the worker to report back

That used to be your job to write into every brief; it is not anymore (#706). Creating the worker
with `from_bufnr` records `orchestrated_by` on it, and vibing.nvim reads that frontmatter on every
turn to inject the report protocol into the worker's own system prompt — this chat's `file_path`
already resolved in, the call shape (`nvim_chat_send_message`, `from_bufnr`, `queue_if_busy: true`),
the report shape (conclusion → what changed → what's unresolved → what's needed next), and what not
to do. The full version is the `vibing-worker` skill, bundled for exactly this purpose. Your brief
only needs to be the task itself, as below — writing the reporting instructions into it too is
redundant, not more reliable, since the injected line does not depend on the worker having read the
brief carefully or at all.

## 4. End your turn — the workers come back to you

Do **not** loop on `nvim_get_buffer` waiting for workers to finish. A turn spent polling burns
tokens, blocks this chat, and will hit the turn limit long before a real task completes.

Once every brief is sent, end the turn with the worker list:

> 3件のワーカーチャットにタスクを配りました（`.vibing/chat/a.md` / `b.md` / `c.md`）。
> 終わり次第ここに戻ります。

Each worker's own report is what wakes you. `queue_if_busy: true` makes that delivery reliable: a
report that arrives while you are mid-turn waits and starts a new turn the moment you stop, and
several arriving together are coalesced into one turn. This works regardless of
`agent.chat_notifications.enabled` — the report is a message the worker chose to send you, not a
notification vibing.nvim volunteers.

That setting governs the **watchdog** instead: with it enabled, a worker that stops _without_
reporting wakes you anyway (step 5). With it disabled, a worker that stopped normally and simply
never reported is silent — say "進捗は?と聞いてください" and wait for the user.

**A blocked worker always wakes you, whatever that setting is.** A worker that stopped to ask a
question, that is sitting on a tool-approval prompt, or whose turn failed cannot report: all three
kill its turn before it could call `nvim_chat_send_message`, and it will not run again until
someone acts on it. Those three are delivered to you regardless of
`agent.chat_notifications.enabled`, and the notice names the status.

## 5. Read what arrived

You get woken in two ways, and they do not mean the same thing.

**A worker's report** — the turn carries its summary as text. This is the normal path, and the
summary is meant to be enough on its own. Do not call `nvim_get_buffer` on that worker unless the
summary actually leaves something open.

**A watchdog notice** — the turn names one or more chats you messaged and says they stopped. Two
shapes, and the difference is whether the notice carries a `status:`.

- **With a status** ("have stopped and cannot continue on their own", each chat listed as
  `— status: asked_question` / `waiting_approval` / `error`) the state is already established:
  that chat is stuck and will not move until someone acts. Act on it from the list; you only need
  `nvim_get_buffer` to read _what_ it is stuck on.
- **Without one** ("have stopped without reporting back") the worker simply stopped without
  reporting, which under the convention above is itself suspect. Read those with
  `nvim_get_buffer({ rpc_port, file_path, last_section: true, tail_lines: 25 })` — not every
  worker, and not a plain `nvim_get_buffer` call: a worker chat can run to hundreds of thousands
  of lines, and reading it in full pulls that whole transcript into this conversation for the
  rest of it. `last_section` + `tail_lines` gets you the end of its last turn, which is normally
  enough to tell "it finished but forgot to report" from "it crashed mid-task"; go back for more
  only if that tail leaves it unclear.

Alongside the transcript the result carries a chat-status line, in the same vocabulary:

- `status: responding` — a reply is still being streamed in. Whatever you just read is partial;
  report it as in progress and do not summarize its conclusion.
- `status: idle` — nothing is in flight. The transcript is complete as far as that worker got, so
  read its last Assistant section for the outcome.
- `status: asked_question` — the worker stopped to ask something and is waiting for an answer.
  Read the question and reply with `nvim_chat_send_message` (passing `from_bufnr`), or put it to
  the user if only they can decide. It will not move until someone answers.
- `status: waiting_approval` — the worker stopped on a tool-approval prompt. By default only the
  user can clear that one: say which worker is blocked and on what. If the user turned on
  `agent.orchestration.delegated_approval` (`true` or `"scoped"`), you can answer it yourself — see
  "Answering a worker's tool approval" below.
- `status: error` — the last turn ended with an error. Read the tail of the transcript for the
  message and decide whether to re-brief the worker or report the failure.

Note that `idle` still means "not currently running", not "succeeded": a worker that did half its
brief and stopped is `idle` too. Read the tail of the transcript before calling a task done. The
three statuses above are the cases that used to hide inside `idle`; a status this server has no
wording for is reported by name, and means the same thing — go read the transcript.

**One report is one turn, so three workers wake you three times.** If workers you dispatched are
still running, do not start aggregating: say in one or two lines what this one produced, and end
the turn. Aggregate only on the last one. An orchestrator that writes a full summary each time
produces three contradictory summaries and pays for all of them.

Track which workers are still outstanding by writing the list into your reply each time — that
text is the only place the count survives between turns.

A worker may also message you directly with a question instead of finishing. Answer it with
`nvim_chat_send_message` (passing `from_bufnr` again, so its reply comes back to you) and end the
turn.

## 6. Aggregate and clean up

When no worker is still running, summarize the results together — what changed, what failed, what
still needs the user. Point at each worker's `file_path` so the user can open the full transcript.

"Not running" includes the blocked statuses above: a worker sitting on `asked_question` or
`waiting_approval` will never reach `idle` on its own, so waiting for it is waiting forever.
Report it as blocked and say what it needs.

### Answering a worker's tool approval

A worker that reaches a tool in its `ask` list has its turn killed and the approval prompt drawn
into its own buffer. It cannot continue and cannot report that it is stuck. **By default the only
one who can clear that is the user** — name the worker and the tool in your reply and end the turn.

If the user set `agent.orchestration.delegated_approval` to `true` or `"scoped"`, you can answer it
instead:

```text
nvim_get_buffer({ rpc_port, file_path: "<worker file_path>" })    # read what it is stuck on
nvim_chat_answer_approval({
  rpc_port,
  file_path: "<worker file_path>",
  action: "allow_once",
  from_bufnr: <this chat's bufnr>,
})
```

The two modes differ in who judges the prompt:

- **`true`: you judge it, every time.** You are standing in for the user on a decision they asked
  to be consulted about. Answer only when the tool and its input are plainly within the brief you
  wrote for that worker. Anything else — a command touching files outside the task, anything
  destructive, anything you cannot place — goes to the user, with the worker and the tool named.
- **`"scoped"`: the call judges it, against that worker's own `delegated_scope` frontmatter**
  (declared when you created it — see step 2). An `allow_once`/`allow_for_session` answer only
  succeeds if the tool matches a pattern you declared up front; a `deny_once`/`deny_for_session`
  answer always succeeds. This means you can just try `allow_once` first — a failure means it is
  out of the scope you declared, so fall back to naming the worker and the tool to the user, the
  same as when the setting is off. Don't try to widen the scope yourself to force a match; that
  defeats the point of having declared it up front.

Regardless of mode:

- **Read the prompt before answering.** The buffer names the tool and its input. Approving a tool
  you have not looked at is not delegation, it is a rubber stamp.
- **Prefer `allow_once`.** `allow_for_session` is written into that worker's frontmatter and
  applies to every later call in it, so it outlives the one call you actually judged. Use it only
  when the brief obviously needs the tool repeatedly. `deny_once` / `deny_for_session` are the
  other two; a denial sends the worker back with "use a different approach", so say why in a
  follow-up message if the reason matters.
- **The call fails with an explanation when the setting is off, or when a `"scoped"` call misses.**
  Read it and put the approval to the user; don't call it again to check.

Answering starts a new turn in that worker, so it will come back to you when it stops — exactly
like a brief. Do not poll it.

If you used worktrees, offer the `vibing-worktree-finish` skill for each branch once its work has
been merged or abandoned. Don't remove a worktree on your own initiative; unmerged work lives
there.

## 7. If you are also someone else's worker

A chat can be a worker and an orchestrator at once: briefed by a parent, and splitting its own task
across workers of its own. Your own reporting duty to that parent is the injected line in your
system prompt plus the `vibing-worker` skill it points to — read that for the report protocol.
Everything above still applies to how you run your own workers — plus one rule.

**Report your own completion to your parent only once every worker of yours has reported.**
Nothing enforces this; there is no barrier in vibing.nvim, and a message sent early is delivered
normally. The whole fan-in is this convention, so keeping it is on you. It covers only the
completion report — the immediate reports the `vibing-worker` skill obligates you to send your own
parent (a heads-up before an approval-prone action, or the moment you find you yourself cannot
proceed) still fire right away, whether or not your own workers have finished.

- While workers are outstanding, end each turn with a line naming which ones you are still waiting
  on. That text is the only place the count survives — you are a fresh process every turn, and
  the wake-up that brings a report carries no tally.
- Report to your parent when the last one is in. One report, summarizing all of them, not one per
  worker: your parent's job is the same as yours, and forwarding raw worker output makes it pay for
  a transcript twice.
- **Do not wait forever.** A worker that stops `asked_question`, `waiting_approval` or `error` is
  not going to report on its own. Deal with it if you can (answer the question, answer the tool
  approval if that is enabled, re-brief it); if you cannot, report to your parent now with that
  worker's state named, rather than holding the whole tree open for something only the user can
  clear.
- If your own brief turns out to be ambiguous, ask your parent before dispatching. Splitting a
  misunderstood task fans the misunderstanding out across several chats.
