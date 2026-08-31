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
- Keep the returned `bufnr` **and** `file_path` for every worker, and write them into your reply
  in this chat. `from_bufnr` records the relationship, but not which worker owns which task — that
  mapping only exists in what you write here, and the transcript is where you read it back from if
  the conversation is resumed later.

## 3. Send each worker a self-contained brief

```text
nvim_chat_send_message({
  rpc_port,
  bufnr: <worker bufnr>,
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

Say in the brief that the worker should report its result in its own chat and stop. Add that if it
gets stuck or the brief turns out to be ambiguous, it should ask you rather than guess — a worker
you passed `from_bufnr` to is told your buffer number and can call `nvim_chat_send_message` back.
A question costs one turn; a worker guessing wrong costs the whole task.

## 4. End your turn — you will be woken

Do **not** loop on `nvim_get_buffer` waiting for workers to finish. A turn spent polling burns
tokens, blocks this chat, and will hit the turn limit long before a real task completes.

Once every brief is sent, end the turn with the worker list:

> 3件のワーカーチャットにタスクを配りました（bufnr 12 / 14 / 16）。終わり次第ここに戻ります。

If completion notifications are enabled (`agent.chat_notifications.enabled`), each worker you
messaged wakes this chat with a new turn when it stops, naming the buffer to read. If they are
not, nothing wakes you — say "進捗は?と聞いてください" instead and wait for the user.

## 5. Read the chat the notification named

A notification tells you which buffer(s) stopped. Read those with
`nvim_get_buffer({ rpc_port, bufnr })` — not every worker. Alongside the transcript the result
carries a chat-status line:

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

**One notification is one turn, so three workers wake you three times.** If workers you dispatched
are still running, do not start aggregating: say in one or two lines what this one produced, and
end the turn. Aggregate only on the last one. An orchestrator that writes a full summary each time
produces three contradictory summaries and pays for all of them.

Track which workers are still outstanding by writing the list into your reply each time — that
text is the only place the count survives between turns.

A worker may also message you directly with a question instead of finishing. Answer it with
`nvim_chat_send_message` (passing `from_bufnr` again, so its reply comes back to you) and end the
turn.

## 6. Aggregate and clean up

When no worker is still running, summarize the results together — what changed, what failed, what
still needs the user. "Not running" includes the blocked statuses above: a worker sitting on
`asked_question` or `waiting_approval` will never reach `idle` on its own, so waiting for it is
waiting forever. Report it as blocked and say what it needs. Point at each worker's `file_path` so the user can open the
full transcript.

If you used worktrees, offer the `vibing-worktree-finish` skill for each branch once its work has
been merged or abandoned. Don't remove a worktree on your own initiative; unmerged work lives
there.
