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

## 1. Split the work

Break the request into tasks that can run without waiting on each other. If two tasks would edit
the same files, either merge them into one task or give each its own worktree with the
`vibing-worktree-create` skill (`git worktree add -b <branch> .vibing/worktrees/<branch>`) — two
chats editing one working tree will overwrite each other, and nothing in vibing.nvim prevents it.

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

### The brief must tell the worker to report back

This is not optional decoration — it is how the fan-out finishes without you polling. Every brief
carries three things beyond the task:

1. **Where to report** — this chat's `file_path`. The worker is told it in its own system prompt
   too, but a brief is read on its own and should not depend on that.
2. **How to report** — `nvim_chat_send_message` with the worker's own chat buffer number as
   `from_bufnr` and **`queue_if_busy: true`**. Without that flag the send is refused outright
   whenever you happen to be mid-turn, and the report is simply lost.
3. **What to report** — the conclusion, what failed, and what needs your action, **briefly**. The
   summary must stand on its own — "Done, read my chat" costs you a `nvim_get_buffer` and pulls
   that worker's entire transcript into this conversation, once per worker — but the opposite
   failure wastes tokens twice: a report that replays the whole working log is paid for once when
   the worker writes it and again when you read it, while that log already sits in the worker's
   transcript for free. Tell the worker to keep the report to the points you will act on; read its
   transcript yourself on the rare occasion you need the detail.

Add that if it gets stuck or the brief turns out to be ambiguous, it should ask you the same way
rather than guess. A question costs one turn; a worker guessing wrong costs the whole task.

A closing paragraph you can paste into a brief:

```text
終わったら、次の呼び出しで報告してから止まってください。

  nvim_chat_send_message({
    rpc_port,
    file_path: "<このチャットの file_path>",
    from_bufnr: <あなた自身の chat buffer 番号>,
    queue_if_busy: true,
    message: "<結果の要約>",
  })

要約だけで判断できる内容にしてください（何を変えたか・何が失敗したか・何が残っているか）。
作業過程の詳細は書かず、要点だけを短く。詳細が必要なときはこちらからあなたの transcript を
読みに行きます。
詰まったとき、ブリーフが曖昧なときも、推測せず同じ方法で聞いてください。
```

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
reporting wakes you anyway (step 5). With it disabled, a worker that never reports is silent — say
"進捗は?と聞いてください" and wait for the user.

## 5. Read what arrived

You get woken in two ways, and they do not mean the same thing.

**A worker's report** — the turn carries its summary as text. This is the normal path, and the
summary is meant to be enough on its own. Do not call `nvim_get_buffer` on that worker unless the
summary actually leaves something open.

**A watchdog notice** — "the following chat(s) you sent a message to have stopped without reporting
back". Under the convention above a finished worker reports, so a stop with no report is more
likely a worker that failed, stopped to ask something, or is sitting on a tool approval. Read those
with `nvim_get_buffer({ rpc_port, file_path })` — not every worker. Alongside the transcript the
result carries a chat-status line:

- `status: responding` — a reply is still being streamed in. Whatever you just read is partial;
  report it as in progress and do not summarize its conclusion.
- `status: idle` — nothing is in flight. The transcript is complete as far as that worker got, so
  read its last Assistant section for the outcome.
- `status: asked_question` — the worker stopped to ask something and is waiting for an answer.
  Read the question and reply with `nvim_chat_send_message` (passing `from_bufnr`), or put it to
  the user if only they can decide. It will not move until someone answers.
- `status: waiting_approval` — the worker stopped on a tool-approval prompt. Only the user can
  clear that one; say which worker is blocked and on what.
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

If you used worktrees, offer the `vibing-worktree-finish` skill for each branch once its work has
been merged or abandoned. Don't remove a worktree on your own initiative; unmerged work lives
there.

## 7. If you are also someone else's worker

A chat can be a worker and an orchestrator at once: briefed by a parent, and splitting its own task
across workers of its own. Everything above still applies — plus one rule.

**Report to your parent only once every worker of yours has reported.** Nothing enforces this;
there is no barrier in vibing.nvim, and a message sent early is delivered normally. The whole
fan-in is this convention, so keeping it is on you.

- While workers are outstanding, end each turn with a line naming which ones you are still waiting
  on. That text is the only place the count survives — you are a fresh process every turn, and
  the wake-up that brings a report carries no tally.
- Report to your parent when the last one is in. One report, summarizing all of them, not one per
  worker: your parent's job is the same as yours, and forwarding raw worker output makes it pay for
  a transcript twice.
- **Do not wait forever.** A worker that stops `asked_question`, `waiting_approval` or `error` is
  not going to report on its own. Deal with it if you can (answer the question, re-brief it); if
  you cannot, report to your parent now with that worker's state named, rather than holding the
  whole tree open for something only the user can clear.
- If your own brief turns out to be ambiguous, ask your parent before dispatching. Splitting a
  misunderstood task fans the misunderstanding out across several chats.
