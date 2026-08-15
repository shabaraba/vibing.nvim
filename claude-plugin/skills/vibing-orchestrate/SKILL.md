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
nvim_chat_create({ rpc_port, position: "back" })
nvim_chat_create({ rpc_port, position: "back", working_dir: ".vibing/worktrees/fix-auth" })
```

- `position: "back"` (the default) creates the buffer without opening a window, so the user's
  layout is untouched. Don't use a split position for workers unless the user asked to watch them.
- `working_dir` is relative to the git root and must already exist — create the worktree first.
- Keep the returned `bufnr` **and** `file_path` for every worker, and write them into your reply
  in this chat. That list is the only record of which worker owns which task; if the conversation
  is resumed later, the transcript is where you will read it back from.

## 3. Send each worker a self-contained brief

```text
nvim_chat_send_message({ rpc_port, bufnr: <worker bufnr>, message: "<the whole task>" })
```

A worker chat starts empty. It has none of this conversation's context: not the user's original
request, not the files already discussed, not the decisions already made. Write the brief as if to
someone who just walked in — goal, the files or directories involved, the constraints, and what
"done" looks like. A brief that says "do the refactor we discussed" produces nothing useful.

Say in the brief that the worker should report its result in its own chat and stop; workers cannot
message you back.

## 4. Hand control back to the user

Do **not** loop on `nvim_get_buffer` waiting for workers to finish. A turn spent polling burns
tokens, blocks this chat, and will hit the turn limit long before a real task completes.

Once every brief is sent, end the turn with the worker list and an explicit handle:

> 3件のワーカーチャットにタスクを配りました（bufnr 12 / 14 / 16）。進捗を見たいときは「進捗は?」
> と聞いてください。

## 5. Report progress when asked

When the user asks, read each worker with `nvim_get_buffer({ rpc_port, bufnr })`. Alongside the
transcript the result carries a chat-status line:

- `status: responding` — a reply is still being streamed in. Whatever you just read is partial;
  report it as in progress and do not summarize its conclusion.
- `status: idle` — nothing is in flight. The transcript is complete as far as that worker got, so
  read its last Assistant section for the outcome.

Note that `idle` means "not currently running", not "succeeded" — a worker that failed, that
stopped to ask the user something, or that is waiting on a tool approval prompt is also idle. Read
the tail of the transcript before calling a task done.

Report per worker: task, state, and the one-line outcome. Then either hand control back again
(some still running) or move to aggregation.

## 6. Aggregate and clean up

When every worker is idle and finished, summarize the results together — what changed, what
failed, what still needs the user. Point at each worker's `file_path` so the user can open the
full transcript.

If you used worktrees, offer the `vibing-worktree-finish` skill for each branch once its work has
been merged or abandoned. Don't remove a worktree on your own initiative; unmerged work lives
there.
