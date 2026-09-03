# Multi-Agent Orchestration

Detail behind `.claude/rules/architecture.md` → "Multi-Agent Orchestration". One chat can create
and drive other chats. The whole feature is three MCP calls and a skill; nothing new was needed
to keep the workers apart, since parallel workers are the existing concurrency guarantee being
used rather than extended.

The long middle of this file is the completion-notification machinery, and it is long because
almost every rule in it exists to stop a specific silent failure — a worker that stopped and told
nobody, or a parent woken about a chat that had already restarted.

One chat can create and drive other chats: `nvim_chat_create` (MCP) →
`infrastructure/rpc/handlers/chat.lua` → `application/chat/use_cases/create_chat.lua` →
`view.render`. The orchestrator briefs each worker with `nvim_chat_send_message` and polls it with
`nvim_get_buffer`. The workflow is the bundled
`claude-plugin/skills/vibing-orchestrate/SKILL.md`; there is no command and no scheduler — the
whole feature is three MCP calls and a skill.

Nothing new was needed to keep the workers apart. Each chat buffer already owns its own session
id and handle id (see "Concurrent Execution Support"), so parallel workers are the existing
concurrency guarantee being used rather than extended.

The use case is the fork/subagent shape: it returns a `ChatSession` and touches no presentation
code, and the RPC handler is what renders it. That is also why position validation sits in the
handler — it is an argument the RPC caller supplied, not a property of the session.

Four things it does differently from `:VibingChat`, each for a reason:

- **`position` defaults to `back`.** The chat exists as a listed buffer with no window. A worker
  the model created is not something the user asked to look at.
- **The chat file is written immediately** (`save_now` in the handler), matching `fork.lua`.
  `:VibingChat` leaves the file unwritten until `update_session_id` fires on the first response,
  so returning the path any earlier would name a file that does not exist.
- **`working_dir` is validated up front.** It is a git-root-relative path like the frontmatter
  field, resolved through `Git.resolve_working_dir`. A missing directory is rejected at creation;
  accepted, it would produce a chat that only fails on its first request, in a buffer the user
  is not watching.
- **The chat file still goes to the configured `save_dir`,** not inside `working_dir`. A worker
  attached to a worktree has to outlive `git worktree remove`, and this matches
  `vibing-worktree-create`, which only rewrites an existing chat's frontmatter. (The pre-existing
  and never-called `use_case.create_new_in_directory` does the opposite; `create_new` takes an
  optional `working_dir` instead.)

`view.render` now returns its `ChatBuffer` and replaces the `window` table before applying a
one-off `position`. It used to assign straight into `chat_buf.config.window.position`, and
`ChatBuffer` holds a reference to the live `config.chat` table — so a single `back` render changed
the user's default position for the rest of the session, right down to `Config.defaults`, which
survives a later `setup()`. Harmless enough at one `:VibingChat back` a day; not harmless when an
orchestrator opens three workers that way. Note that `vim.tbl_deep_extend("force", {}, cfg)` does
**not** fix it: with an empty base nothing collides, so every nested table is assigned by
reference and `config.window` stays the same table.

**Completion detection is a status field, not a text heuristic.** `nvim_get_buffer` passes
`include_chat_status` to `buf_get_lines`, which attaches `presentation/chat/modules/chat_status`'s
verdict: `"responding"` when `ChatBuffer:is_responding()`, one of `"waiting_approval"` /
`"asked_question"` / `"error"` when the last turn stopped for a reason worth naming, `"idle"`
otherwise, and nothing at all for a buffer that is not a chat. Reading the transcript's shape
instead would call a turn that died on an error, or one part-way through silent tool calls,
complete.

`is_responding()` needs two signals, and the second one is **not** `_current_handle_id`'s
existence. `_is_sending` covers `<CR>` until the adapter spawns the CLI; after that the handle id
is what marks the run — but `send_message.lua` deliberately never clears it on completion, so the
next `send_message()` can kill a process that outlived its own `result` event. Read as a boolean
that field therefore reports every chat as `responding` forever after its first turn, which is the
one answer an orchestrator's polling loop can never recover from. So the second signal is
`ActiveStreamRegistry.get(handle_id)`: all four adapters `register` when the stream starts and
`unregister` in `wrapped_on_done`, which makes the registry the only place that knows a run is
over without also being the place that has to remember how to kill it.

One window stays uncovered: `_handle_response` clears `_is_sending` before the `vim.schedule` that
appends the next `## User`, so a poll landing in that tick reads `idle` while the buffer is still
growing. The reply itself is already complete by then — what is pending is the diff footer. The old
boolean check did cover this window, but only as a side effect of being true forever.

The flag is opt-in rather than a new return shape because the MCP server installs at Claude
Code's _user_ scope and updates independently of the plugin: without a parameter to key on, a
newer Neovim answering an older server would hand it an object where it calls `.join()`. Both
directions of that skew are covered — the Lua side returns the bare array unless asked, and the
Node side accepts either shape.

`idle` means "no request in flight", not "succeeded". The three named stops carve out the cases
that used to hide inside it — a turn that ended on an error, one holding a tool-approval prompt,
one that asked a question — but what is left is still only "nothing is running": a worker that
finished half its brief and stopped is `idle` too. Whether the _task_ is done is something only the
worker's own report can say, which is why the notification below never claims it.

The reason lives on `ChatBuffer._stop_reason`, and **each of its three writers sets it at the moment
the fact becomes true** rather than a single pass reconstructing it at the end:
`insert_choices` writes `asked_question`, `insert_approval_request` writes `waiting_approval`, and
`mark_turn_error` — a callback `_handle_response` fires on its two failure paths — writes `error`.
Last write wins, which is right because each of those events is itself where the turn stops.

Deriving it at the end instead is the version that looks tidier and is worse: `add_user_section()`
clears `_pending_choices`, so the derivation would have to be ordered ahead of that call, and an
ordering rule that only a comment enforces is one a later edit silently breaks. `send_message()`
clears the field, which is the one piece of bookkeeping left: a turn that dies before its next send
must not leave its reason describing the following turn.

`mark_turn_error` skips two kinds of turn, and both exclusions are load-bearing rather than tidy:
what `chat_status` calls `error` is what branch 2's exception wakes the parent for, so anything
that is really still _waiting_ must stay out of it.

- **`_cancelled`** — a question and an approval prompt both stop the turn _by cancelling it_, and
  the reason was already written by `insert_choices` / `insert_approval_request`.
- **`_rate_limit_info`** — the limit branch above has already parked the turn as a scheduled send
  or an auto-resume, so it will restart on its own. `response.error` still holds the limit text
  (`RateLimit.merge` reads it as one of its inputs and does not clear it), so without this guard
  _every_ parked turn reports `error` and an orchestrator reads a healthy worker as failed.

A parked turn is therefore `idle`, which is the pre-#640 behaviour: distinguishing "waiting on a
reset" would be a fourth stop reason, and that was deliberately left out of this change.

A status the MCP server has no wording for is **named rather than dropped**. `CHAT_STATUS_TEXT` is
a lookup table, and rendering nothing for `error` or `waiting_approval` would read as a healthy
chat — the same silent-ignore failure `plugin_dirs`' manifest check exists to prevent — so a miss
falls back to a line carrying the raw status. That matters because the server is versioned
separately from the Lua side and can be handed a value added after it shipped.

**The relationship is recorded in frontmatter, not in the transcript.** `orchestrated` on the
orchestrator, `orchestrated_by` on the worker, both git-root-relative path lists written by
`application/chat/orchestration_link.lua` when `nvim_chat_create` or `nvim_chat_send_message` is
given an optional `from_bufnr`. `infrastructure/link/orchestration_chat_scanner.lua` keeps them in
step through `:VibingSetFileTitle`, alongside `ForkedChatScanner`.

Before this, the only record was prose the skill told the orchestrator to write into its own
reply, and it decayed two ways: **bufnrs are per-session** (a restart makes the number point at
some unrelated buffer) and **file paths get renamed out from under it** by `:VibingSetFileTitle`.
Frontmatter plus a rename scanner is how `forked_from` already solves exactly this, so the shape
is borrowed rather than invented.

Four details are load-bearing:

- **`from_bufnr` is optional, in both directions of version skew.** The wire format carries no
  protocol version, so an older Neovim ignores the extra key and an older MCP server never sends
  it. Requiring it would turn a forgotten argument into a refused send — a worse failure than a
  missing link, and one that would break every existing caller at once. Present-but-wrong is the
  opposite case and errors the call (`bufnr.resolve_from_bufnr`, #661): a number that names no
  chat buffer — typically one remembered from before a Neovim restart — used to drop the link
  _and_ the completion subscription in silence while the caller was told the call succeeded, and
  the MCP caller is the one party that can correct it. The check runs before any side effect, so
  a refused `nvim_chat_create` leaves no orphaned worker chat behind.
- **The link is written before the message is sent.** `update_frontmatter_list` edits the buffer
  directly, so writing after the worker's reply starts would race its streaming.
- **`update_frontmatter_list` writes to the buffer, not to disk**, and the rename scanner reads
  disk. So `orchestration_link` saves both files itself. The sender is the one that needs it:
  `:VibingChat` holds the first write until the first response, so an orchestrator that dispatches
  on its opening turn has no file for a scanner to find.
- **One scanner reads both keys.** Splitting it per direction would double the full-file reads and
  the `git rev-parse` calls over the same directory, and a rename has to update whichever side
  names the old path anyway.

Copying `ForkedChatScanner` wholesale is the trap here. `forked_from` is a scalar, so its
`update_link` hands the whole key to `Frontmatter.update`; doing that to a list drops every other
element. `OrchestrationChatScanner` replaces the matching element and dedupes afterwards, since a
rename can collide with an entry the list already had. Two parser behaviours bite the same way: an
empty list parses to a **truthy** `{}`, and a hand-written `orchestrated: path.md` parses to a
**string** rather than a list.

**A send whose reverse is already recorded writes no link**, and that is what keeps the record a
tree rather than a set of pairs. A push report (#643) is a `nvim_chat_send_message` in the opposite
direction from the dispatch, so writing it as a new relationship put each worker into its
orchestrator's `orchestrated_by` — and `cli_command_builder` builds the worker prompt out of that
key, so the orchestrator was then told to report to its own worker. Reproduced across three chats
before fixing. The mechanism still cannot tell a report from a request at send time, which is the
constraint `completion_notifier` documents; what it can read is whether the recipient is already
this chat's orchestrator, and that answers the direction question on its own. One side recording it
is enough, since `link` tolerates a half-written pair. The cost is that a genuine A⇄B mutual
orchestration cannot be recorded — a cycle, and not a shape worth supporting.

A one-sided write warns rather than failing the send: the link is a record, and rename sync still
works from whichever side did get written. Fork and subagent chats do **not** inherit these fields
— `inherited_frontmatter.from_source` is an explicit whitelist, and a fork claiming its parent's
relationships would be claiming work it was never given.

**Completion is pushed, not polled** — `agent.chat_notifications.enabled`, default `false` because
it spends tokens unattended. The whole mechanism is that **the send is the subscription**: when
`nvim_chat_create` / `nvim_chat_send_message` receive `from_bufnr`, `completion_notifier.subscribe`
records an A←B edge, and when B's turn ends A is given a new turn saying "B stopped, go read it".
A worker asking its orchestrator a question is the same path in reverse — it just calls
`nvim_chat_send_message` itself.

There is no waiting anywhere, and there cannot be: the CLI process dies when its turn ends, so the
only way to deliver anything to a chat is to _start a new turn on it_.

**What that flag gates is narrower than it reads.** It governs the
watchdog — the notice vibing.nvim volunteers about a chat that stopped normally. It does **not**
gate a stop the chat cannot leave on its own: `asked_question`, `waiting_approval` and `error` are
delivered to every subscriber whatever the setting is. Three facts make that the only coherent
line. Each of those three ends the turn by killing it or failing it, so the chat has no
opportunity to call `nvim_chat_send_message` — the report convention, which is ungated, cannot
cover them by construction. None of them clears without someone outside acting. And a worker's
buffer is a windowless `back` chat nobody is looking at. Put together, gating them behind an
opt-in meant that on the default configuration a worker hitting its first tool-approval prompt
stopped the whole tree in silence, which is the failure this module exists to remove.

So `subscribe` no longer refuses while the flag is off — the edge is the _precondition_ for a
delivery, not the delivery — and `process_done` reads the flag only after establishing that the
stop carries no reason. The edge is still consumed on a real stop either way, so switching the
flag on does not fire a backlog of old subscriptions. `max_round_trips` and `max_wakes` bound both
kinds of delivery, since a runaway is a runaway.

The same correction applies to the worker's system-prompt orchestrator line, which
`send_message.lua` also used to skip while the flag was off, on the reasoning that "there is no
route to wake the orchestrator anyway". That reasoning was wrong in the same way: a worker's
report is an ordinary `nvim_chat_send_message`, and both the direct send and `queue_if_busy` have
always been ungated. The default configuration was therefore running workers that had never been
told who to report to — disabling the _primary_ path in order to disable the watchdog.

`enqueue_notification` carries the reason through to the delivered text, so the notice reads
`- .vibing/chat/w.md (chat buffer 12) — status: waiting_approval` and says which of the three it
is. A repeat notice about the same chat still coalesces into one line, but the **newer** reason
wins: what the reader needs is that chat's current state, not the first thing it was.

The completion event fires from the `callbacks.add_user_section` wrapper in `buffer.lua`, and
every word of that placement is load-bearing:

- **The four completion paths in `_handle_response`** (session corruption, mote `finalize`,
  no-file-change, git patch `finalize` — two of them inside `vim.schedule`) all converge on that
  one callback. Nothing else does.
- **Not `ChatBuffer:add_user_section()` itself**, which the slash-command path also calls — that
  would report a completion for a turn the model never ran.
- **Not next to `clear_sending()`**, which under `diff.tool = "mote"` runs before `finalize()`
  writes `### Modified Files`. A reader woken there would see an unfinished transcript, the same
  window `chat_status` documents.
- **After the handle_id mismatch guard**, so a cancelled turn completing late fires nothing.

It goes out as a `User VibingResponseDone` autocmd rather than a direct call so a user's own config
can hook it too — before this there was no `nvim_exec_autocmds` anywhere in `lua/`.

**Delivery refuses a busy buffer, and that is the sharpest edge in the feature.**
`ChatBuffer:send_message()` cancels the in-flight request before starting a new one, so delivering
into a responding chat would kill the turn it is in the middle of; and its `_is_sending` guard
returns _silently_, so `ProgrammaticSender` used to report success for a message it never sent —
leaving an orphan `## User` section that became the body of the user's next `<CR>`. A dispatched
chat normally keeps working after dispatching, so the shorter the worker's task the more likely
this window is. So `ProgrammaticSender` now refuses before appending (rather than appending and
rolling back), and `application/chat/message_queue.lua` queues instead, flushing on the
recipient's own completion event. Queued items coalesce into one message: three workers finishing
while the orchestrator is busy is one turn, not three.

**That queue carries bodies as well as notices**, which is what `nvim_chat_send_message`'s
`queue_if_busy` is (#642). Both kinds need the same wait — the only way to deliver anything is to
start a turn, and a turn can only be started on a chat that is not responding — so they share one
queue and one flush, and a turn woken by it can carry both. An item with a `body` is a relayed
message and one without is a completion notice — there is no separate kind flag, because a
derivable one goes stale. `application/chat/delivery_message.lua` renders the coalesced turn and
keeps the notice-only case byte-identical to what it was, since that is still the common shape;
splitting it out keeps prompt wording out of the queue's state machine.

Four things about it are not incidental:

- **`queue_if_busy` is not gated on `chat_notifications.enabled`, and the drain is not either.**
  That flag decides whether vibing.nvim volunteers a watchdog wake-up; a queued message is a
  delivery the caller explicitly asked for. Gating it would mean a worker's report vanishing in
  silence on the default config. So `on_response_done` drains first and unconditionally, and the
  `edges` half below it reads the flag only for a chat that stopped with no reason attached
  (see the flag's own note above).
- **It is off by default on the tool, in both directions of version skew.** An older Neovim
  ignores the key and refuses a busy chat exactly as before, which is what a caller that did not
  ask to queue already expects; an older MCP server never sends it. It also only covers
  `"responding"` — an invalid buffer or an empty message is not something waiting fixes, so those
  still error. That is why `ProgrammaticSender` grew a `is_responding` predicate rather than the
  caller matching on the error _text_ `validate` raises, which would stop working the day the
  wording changed, silently.
- **The orchestration link is written just before delivery, not when the message is queued.**
  `update_frontmatter_list` edits the recipient's buffer, and the precondition for queueing is
  that the recipient is streaming — so the usual "link before the send" ordering has to be kept by
  moving both, not by writing early. Flush only ever delivers into an idle chat, which makes that
  the one safe moment. A message whose recipient is deleted before delivery therefore leaves no
  record of an exchange that never happened.
- **The queue is capped per buffer (20) and a message past the cap is refused, not dropped.** A
  notice can be deduplicated by the bufnr it is about; a body cannot, so a worker in a retry loop
  would otherwise pile up without bound. The refusal is returned to the sender as an error, which
  is the whole point — a report that disappears quietly is the failure this mechanism exists to
  remove. The one case that cannot be reported back is a _notification_ arriving at a full queue,
  since its edge is already consumed by then; that one warns. `forget` follows the same rule when
  a chat is deleted: a notice _about_ that chat has lost its subject and goes, but a queued body
  whose **sender** was the deleted chat is still deliverable, so it loses only the sender's name
  and arrives anonymously.

**A message the sender delivered itself silences the watchdog for one stop.** A send is one event
with two opposite consequences, so `completion_notifier.on_sent(from, to)` performs both rather
than leaving the pairing to each caller: it records `edges[to][from]` (the send _is_ the
subscription), and marks `edges[from][to]` as already-reported, dropping any notice about `from`
already sitting in `to`'s queue. "B stopped, go and read it" is the same errand as B's own report,
and A does not need waking twice for it. The reversed indices are the reason it is one function:
written out at a call site, `subscribe(a, b)` next to a suppression of `edges[a][b]` reads like a
typo.

**It is a mark and not a deletion, and that distinction is the whole of #638 again.** Nothing at
send time can tell a final report from a progress note — and in a tree the middle node's first
message is _always_ a progress note, because it stops once to wait for its own worker and only
writes the real answer after that worker reports. Deleting the edge there would lose the
orchestrator's subscription permanently, defeating the hold this PR's base branch added. So the
mark suppresses exactly one stop: `on_response_done` clears it when the drain restarts the chat
(the report was not final after all), and otherwise consumes the subscription silently, since the
one-shot edge was spent on a delivery the subscriber already received. That consumption happens
**before** the `enabled` gate, not after — a mark is a one-stop temporary, so a completion the
gate declines to act on still has to spend it, or a spell of the feature being off leaves a stale
mark that silences the first genuine edge after it is turned back on.

**Queued messages do not spend hop budget.** A direct send to an idle chat has never counted
against `max_hops` — it just starts a turn — and `queue_if_busy` is that same send arriving late.
Only notices carry a `depth`, and the queue treats it as an opaque number it hands back on delivery
so the notifier can raise its counter; the queue itself never interprets it. Bounding A⇄B
ping-pong through direct sends is #644's pair-wise counter, not this.

**A chat drains its own queue before it notifies anyone, and a turn that drained is not reported as
a completion at all.** `on_response_done` tries `flush(bufnr)` first and returns leaving
`edges[bufnr]` intact when it delivered, because a delivery _is_ a restart — so the turn that just
ended was an intermediate one, and the real answer is still being written.

The order used to be the reverse, on the reasoning that draining first would let a subscriber be
told "B stopped" about a B that had already started again. It does not prevent that. The order
fixes only who is _sent to_ first within one tick, and a subscriber is a separate CLI process that
reads seconds later — by which time the synchronous drain has long since restarted B. The edge is
one-shot, so B's actual report, the turn after the restart, then had nothing left to notify
through. In a tree of chats where a middle node waits on a leaf this happens every time rather than
sometimes: "B's queue is non-empty" _means_ "B is about to restart" (#638).

A drain the recipient **refuses** — it is responding, or the user has a draft in it — restarts
nothing, so subscribers are notified exactly as before.

**The mirror ordering is covered by a second branch, which is #640.** When the leaf finishes
_after_ the middle chat's dispatch turn rather than before — the commoner case, since dispatching
takes seconds and the leaf takes minutes — that turn's queue is empty, so the drain above catches
nothing. The signal that does catch it was already in the table: `edges[c][b]` exists from B's send
until C completes and means "B is waiting on a chat that has not finished". So `on_response_done`
now reads as three branches, tried in order:

1. **The queue drained** — B restarts in this tick, so nothing is delivered and `edges[b]` is kept.
2. **B is waiting on chats it messaged** — the turn that just ended was B parking on a barrier, so
   the parent's notification is held and `edges[b]` is kept.
3. **Neither** — B has really stopped, so subscribers are notified and the edges consumed. This is
   the watchdog.

Branch 2 has one exception, and it is what stops the barrier becoming a trap: a chat that stopped
to **ask a question, wait on a tool approval, or fail** fires to its parent anyway. Nobody is
looking at a worker's buffer, so holding those would leave the whole tree waiting on an answer no
one can give.

The predicate reads `ChatBuffer:get_stop_reason()` directly and asks only whether it is non-nil —
**not** `chat_status`. Going through that vocabulary would mean encoding "must not match
`responding` or `idle`" here, so a stop reason added later would be classified as "needs no
attention" by omission, in silence. Testing the primitive puts a new reason on the firing side by
default, which is the safe direction. `chat_status` stays what it is: the presentation join of
`is_responding()` and the reason, for the MCP field.

**Branch 2 excludes edges pointing back at its own subscribers, and that exclusion is what keeps
it from deadlocking.** `on_sent` makes every send a subscription in both senses — B reporting to A
subscribes B to A's completion — so counting edges naively, a worker that reports to its
orchestrator is "waiting on" that orchestrator. Holding B's completion for A while A waits for B's
completion is a standoff neither side leaves. Nothing in the table says which send was a report
and which was a request, but the direction that _is_ readable is "this chat is waiting on my
completion", and someone waiting on you is not someone to hold your stop from.

What remains, after that exclusion, is the shape branch 2 is actually for: B is waiting on a chat
that is not waiting on B — a leaf it dispatched to.

Two limits are worth writing down, because the rules read more general than they are.

- **The hold is gated on a turn actually starting, not on the send being accepted.**
  `send_message()` returns "treated as a request", which is also true for a message _parked_ behind
  a usage limit (`_try_schedule_instead_of_send`) and for one `SendMessage.execute` drops at its
  no-adapter or shared-session guards — both `clear_sending()` and return without a stream, so no
  `VibingResponseDone` is ever coming. `flush` therefore reports the recipient's `is_responding()`
  rather than the send's own result: a turn that never began cannot be the one a subscriber waits
  for, and notifying now is exactly what the old order did.
- **A held edge still has no exit but `BufDelete`, and branch 2 widens the window.** Every edge
  used to be consumed on the subscribed chat's next completion; one that waits on a follow-up turn
  is stranded silently if that turn dies before reaching the `add_user_section` wrapper. Branch 2
  extends that from "until B's next turn" to "until every chat B messaged has completed", so a
  leaf whose Neovim-side turn vanishes without firing `VibingResponseDone` leaves its parent
  waiting for good. A leaf that merely _fails_ is fine — the failure path still reaches the
  wrapper, which is exactly what the `error` exception is there to convert into a notification.
  What is left uncovered is the process dying under it, and the recovery for that is the same one
  #639 names for a Neovim restart: a human sends a message in the stalled chat, which re-creates
  the edges. Accepted for the reason the module holds no timers.
- **A chat created and never briefed is an edge that never resolves.** `nvim_chat_create`
  subscribes at creation rather than at the first send, deliberately — so a forgotten `from_bufnr`
  on the brief cannot silently cost the notification. Branch 2 now reads that same edge as "the
  creator is waiting on this chat", and a worker that is created and then never messaged runs no
  turn, so nothing ever consumes it. Its creator holds its own parent's notification indefinitely.
  Harmless at the top of a tree (the user is the parent), and the normal flow — create, brief,
  worker completes — clears it. Narrow enough to accept rather than key the barrier off a second
  "has been messaged" table.

None of that promises B's next turn is a report for A rather than a reply to the leaf either. Under
a one-shot edge, "when B next stops" is simply the best moment available.

Edges are **one-shot** — delivering consumes them, so a worker completing again without a fresh
send is silent, and A messaging B three times still notifies once.

**The chain is bounded per chat pair, not per chat.** A→B→A→B is a legitimate question-and-answer,
so this counts rather than detecting cycles: `max_round_trips` (default 8) is how many
notifications may be delivered between one pair of chats without a human `<CR>`, and `subscribe`
refuses once the pair is spent — with a warning, rather than declining in silence.

The pair is **undirected**. What is bounded is the A⇄B ping-pong, and a worker asking its
orchestrator a question arrives as `subscribe(B, A)` while the orchestrator's brief was
`subscribe(A, B)`. Two directional counters would give one conversation two budgets and put the
real ceiling at twice the configured one. The cost of that choice is that the unit is a
_delivery_, not a full exchange: an orchestrator waking on its worker's completion spends one,
but a worker's question and the orchestrator's answer spend two.

It used to be one counter per chat — `depth[bufnr]`, how many times that chat had been woken —
and in a tree that stopped the wrong thing (#644). An orchestrator is woken once per worker
completion, so five workers reporting in spent five of its eight hops before any ping-pong
happened at all: the limit fired on fan-in, which is the normal shape of the feature, and left
A⇄B free until that same shared budget happened to run out. Keyed by pair, fan-in costs each pair
one and only the ping-pong accumulates.

Moving to pairs also removed machinery, and the removal reaches across the module boundary. The
old counter had to be monotonic across a chain, so each edge carried the depth it was created at,
every queued item carried it onward as `Item.depth`, `MessageQueue.flush` returned the deepest of
them, and delivery raised the recipient to `max(current, deepest + 1)` — all of that to stop an
edge subscribed early and delivered late from lowering the count. A pair counter is incremented
from the delivery's own `(from, done)`, which _is_ the pair, so the queue stops carrying a number
it never interpreted. `flush` now reports **which** chats the delivered notifications were about
instead, and that list doubles as the "did anything go out" signal the wake budget needs — an
empty table for a turn that carried only queued bodies, `nil` for no delivery at all.

`max_wakes` (default 50) is the second bound: notifications delivered without a human `<CR>`,
counted across the whole editor. It exists for the shapes a pair counter is bad at, which are the
ones that spread deliveries over many pairs — an unbounded fan that never reaches the same chat
twice, and a long cycle (A→B→C→A advances three counters by one per lap). Which of the two limits
fires first depends on the shape and the configured values; at the defaults a 3-chat cycle is
still caught by `max_round_trips` first, at 24 deliveries, well under the budget.

It is deliberately **not** scoped to a connected component, and the reason is sharper than "more
work". The budget is checked in `subscribe`, and the escape it exists to catch — a fan reaching
chats never contacted before — has no `round_trips` entry at that moment, so component membership
is precisely unknowable for the case it guards. `edges` cannot supply it either: edges are
one-shot and consumed on delivery, so the live set is a transient slice rather than the chat
graph. The accepted cost is that two unrelated orchestrations share one budget — either can
exhaust it for the other, and a `<CR>` in either refills both.

Both reset on a manual `<CR>`, through `on_manual_send(bufnr)`. It is named for the event rather
than for the buffer, matching `on_response_done`, because it is not "clear this chat's state": it
is "a human acted", and what that implies is the module's to decide. So it drops every pair that
chat belongs to _and_ zeroes the tree-wide budget — a human typing anywhere breaks the "running
unattended" premise that budget guards, and keeping it would leave a chain the user is actively
steering unable to notify anyone until Neovim restarts.

The reset lives in the `<CR>` keymap callback rather than in `send_message()`, because delivery
itself goes through `send_message()` — resetting there would zero the counters on every hop and
disable the limits entirely.

**Both limits are checked only when the subscription is created, never again at delivery.** An
edge that was authorized while budget remained is still delivered after other edges have spent it,
so either limit can be exceeded by however many edges were live at that moment. Checking again in
`flush` was rejected: it would drop an already-authorized completion notice, and an orchestrator
silently never hearing that its worker finished is the exact failure this whole mechanism exists to
remove — worse than a one-off bounded overshoot, after which every further `subscribe` is refused
and the chain stops anyway.

A deleted buffer's pair counters go with it (`forget`), since Neovim reuses buffer numbers and a
stale entry would throttle an unrelated new chat on its first send. Emptied inner tables are
dropped along with the entry, in `round_trips`, `edges` and `reported` alike: `forget` runs from a
pattern-less `BufDelete` and short-circuits on `next()` over those three, so a table left holding
zero entries would disarm that fast path for the rest of the session and put a full scan back on
every ordinary buffer close.

The removed `max_hops` is not silently ignored: `config.lua` drops it and warns through
`notify.warn_once`, so the message appears once per Neovim session rather than once per `setup()`
— a config that calls `setup()` again does not repeat it. That is the same treatment
`diff.tool = "mote"` gets, and the three of them share the mechanism rather than each keeping a
flag. A limit that reads as configured while doing nothing is worse than one that was never set.

**The notification says "stopped", never "succeeded".** `idle` is also what a failed turn, a
pending tool approval, and an `nvim_ask_user_question` look like, so judging outcomes from the
event would repeat `chat_status`'s mistake. The message names each finished chat by path (with its
current bufnr in parentheses) and instructs A to read the transcript's tail — not the worker's
text, which would pull B's context into A for no reason.

**Reporting is the worker's job; the notification is a watchdog** (#643). A worker is told — by the
system-prompt line below, and again by the brief `vibing-orchestrate` has the orchestrator write —
to finish by calling `nvim_chat_send_message` on its orchestrator's path with `queue_if_busy: true`
and a summary that stands on its own — and stays brief: the conclusion, failures, and what needs
the orchestrator's action. The working detail is deliberately left in the worker's transcript,
which already exists for free — a report that replays it is paid for twice, once written and once
read, for context the orchestrator can fetch on the rare occasion it wants it. That is the path a
healthy fan-out takes, and it needs
nothing from `chat_notifications`: `queue_if_busy` and the drain are ungated, so a report is
delivered whether or not the watchdog is switched on.

Which is what lets the notice be worded as a warning rather than a status line. `on_sent`'s
suppression mark drops the watchdog for the stop that follows a worker's own report, so a chat that
reaches `enqueue_notification` is one that stopped **without** reporting — likelier a failure, a
question or an approval prompt than a finished task. `delivery_message.lua` says so in as many
words, and the skill's step 5 splits the two wake-ups on that line: a report is read as text, a
watchdog notice sends the orchestrator to the transcript.

The suppression mark has the same exception branch 2 does, and for the same reason: a report is
only redundant with a stop that says nothing new. A worker that reports and _then_ falls into
`waiting_approval` has produced a fact its report does not carry, so that stop is delivered even
to the chat it just reported to. Where a reason is known, `delivery_message` drops the "stopped
without reporting back" wording — that phrasing is an inference about a silent stop, and stating
it about a chat whose state is established would be a guess printed over a fact.

**Fan-in is a convention, not a barrier.** A chat that is both a worker and an orchestrator holds
its own report until every worker of its own has reported — stated in `vibing-orchestrate` step 7,
enforced by nothing. A barrier in the mechanism would have to answer "what if a child never
reports", and both honest answers are bad: a timeout, or a tree that stalls for good. The
convention instead tells the middle node to report early, naming the stuck child, when a child
stops on `asked_question` / `waiting_approval` / `error` — the same three exceptions branch 2
already makes. Worth revisiting if a middle node forgetting turns out to cost anything in practice.

A worker learns its orchestrator from a system-prompt line built out of its `orchestrated_by`
frontmatter, on every turn regardless of `chat_notifications.enabled` (see above; the report
path that line describes was never gated). Only that direction is exposed: a worker's list
is written once at creation and stays byte-stable across turns (#469), while an orchestrator's
`orchestrated` grows with each dispatch and would move the cached prefix mid-conversation.

**Out of scope, deliberately:** the orchestrator still does not poll inside its own turn, and
nothing is persisted — the subscription table and the delivery queue are in memory only, since
Neovim dying takes the worker chats with it. Backends other than claude can be _notified_ (the
event is backend-agnostic) but cannot _subscribe_: `nvim_chat_send_message` is an MCP tool, and
codex/grok reach no MCP server, the same constraint `features.md` records for AskUserQuestion.

## Tree operations

`:VibingOrchestrationTree [path]` draws the tree a chat belongs to with each node's status,
`:VibingCancelTree [path]` stops a subtree, and `agent.orchestration.max_concurrent` (default
`0` = unlimited) caps how many chats may be responding at once (#645). Three decisions carry
the design:

- **The tree is read from frontmatter, buffer-first.** `orchestration_tree.lua` resolves each
  node through the open buffer when there is one and the file on disk otherwise. Most nodes are
  windowless `back` workers, and an orchestrator appends to `orchestrated` on every dispatch, so
  either source alone silently truncates the tree. Reading frontmatter is also what makes the
  tree survive a restart; the _status_ half does not — it lives only on attached buffers, so a
  chat running in another Neovim renders as `[not open]`. Rendering always starts from the root
  (`root_of` follows the first `orchestrated_by` entry when a hand-edited file lists several —
  picking one beats refusing to draw), and a cycle is cut with `(shown above)` rather than
  followed.
- **`:VibingCancelTree` drops every target's queue and subscriptions before the first cancel**
  (`use_cases/cancel_tree.lua`). `cancel()` runs `wrapped_on_done` synchronously, which drains
  the queue — cancelling in order with the queues intact restarts nodes as fast as they are
  stopped. Dropping the edges also keeps the watchdog quiet about these stops: the human asked
  for them, so "this chat stopped without reporting" would be false. The subtree is computed
  from the same frontmatter as the visualization, so a hand-written cycle makes "descendants"
  reach ancestors — a cancel inside such a loop stops chats above the named node. The loop is
  visible in the tree beforehand; accepted rather than special-cased.
- **The concurrency cap gates machine-started sends only** (`concurrency.lua`, enforced in the
  RPC send handler and the queue drain, never in `ChatBuffer:send_message()` — a human `<CR>`
  always goes through). The count includes every responding chat, the user's own manual turns
  included, so one long hand-driven turn occupies a slot. A send held by the limit is **not** a
  stop: the hold is treated like branch 2 above (edges kept, no notification), redelivery when a
  slot frees is limited to `held_by_limit` entries — retrying every non-empty queue on each
  completion re-delivers refused messages, which a spec pins — and a `queue_if_busy` message
  held against an _idle_ recipient registers via `hold_for_capacity`, since no completion event
  of the recipient's own is ever coming to trigger the retry.

  It inherits branch 2's exception as well, and that is not decoration. A chat holding an
  approval prompt or a question keeps it in the unsent `## User` section, so when the slot frees
  the retry is refused as a draft — the same refusal that makes `flush` safe. That chat runs no
  further turn and fires no further completion event, so a hold decided **before** the stop
  reason was read stranded the parent for good, on exactly the stops this mechanism exists to
  surface. `process_done` therefore reads `stop_reason_of` ahead of the hold, and a held chat
  with a reason notifies its subscribers like any other blocked one. Reachable only with
  `max_concurrent` set, since the default `0` never holds anything.

## Delivered sections

A message that arrived from another chat is written as its own section kind — `## Request`,
`## Report` or `## Notice` — instead of the `## User` a human types into. The grammar and the
three kinds are in `features.md` → "Message Timestamps"; what belongs here is why the seams are
where they are.

**`extract_role` answers `user` for all three, and that is the whole safety argument.** A
section's body _is_ the prompt handed to the CLI (`conversation_extractor.extract_user_message`
takes everything under the last `user` header), so a genuinely separate role would have to be
taught to the send path, the conversation extractor, `commit_user_message`, both daily-summary
parsers and the jump commands — and forgetting any one of them fails toward a delivered turn that
is never sent, which is the silent-loss shape this whole area exists to remove. Only the display
needed splitting, so only the display splits: callers that care read `parse_header().kind`.

**The header grammar has one home.** `timestamp.lua` writes and reads it; `grep_parser` used to
carry its own `^## User` patterns and now calls `extract_role`, because a second reader is a
reader that goes stale — delivered turns would have dropped out of the daily summary without
anything saying so. Its `grep -E` prefilter still names the kinds, which is the one place the list
is repeated, and deliberately: it only decides which lines are handed to the shared parser.

**Both delivery paths build the same text.** `handlers/message.lua` (immediate) and
`message_queue.flush` (queued) both go through `delivery_message.deliver`, which owns the
`section_for` → `build` → send ordering. Leaving those three at each call site is what let them
diverge — the queue wrapped each body in a `### From` heading and the direct send passed the raw
text through — so the same worker's report looked different depending on whether its orchestrator
happened to be mid-turn when it arrived. `section_for` names the sender in the section header only
when the delivery is exactly one body from one chat; `build` then drops the `### From` that would
otherwise repeat it two lines later. A coalesced delivery keeps the per-item headings and leaves
the section header unnamed.

**A delivery fills the empty unsent section rather than appending below it.** Every turn ends with
`add_user_section()` writing `## User <!-- unsent -->`; a human types into it, but
`ProgrammaticSender` appended a second section, so each delivered turn left a stranded empty
`## User` above it — one per turn, visible in any orchestrated transcript. It now drops a trailing
unsent section that is empty. Only empty: the approval prompt and the question list are rendered
into that same section, and dropping those would delete what the user was about to answer.

**The unsent-then-commit dance is kept for delivered sections too.** Writing the timestamp
directly at delivery would be simpler, but a send that lands under a usage limit is parked as an
unsent section and fired later (`auto_resume`), so the unsent form has to exist for these as well.
`commit_user_message` therefore stamps whatever kind it finds and preserves the `from`, instead of
replacing the header with a `## User`.

## Addressing a chat

**The chat file path is the identifier; the bufnr is a per-session resolution of it** (#641).
`nvim_chat_send_message` and `nvim_get_buffer` both take `file_path` or `bufnr`, and the system
prompt's orchestrator line leads with the path — `.vibing/chat/x.md (currently buffer 12)`.

The problem it fixes is that the durable layer was already right and only the volatile one was
being spoken. `orchestrated` / `orchestrated_by` hold paths, `OrchestrationChatScanner` keeps them
correct across renames, and none of that reached the model: a bufnr means nothing in a Neovim other
than the one that issued it, so a chat network resumed the next morning pointed every edge at some
unrelated buffer. Recovery is by design "a human kicks a node" (see #639), and a kicked node can
only re-attach if what its frontmatter records is also what it can address.

Five details are load-bearing:

- **A path that names no open chat is opened, not refused.** `application/chat/chat_locator.lua`
  does `bufadd` + `bufload` + `view.attach_to_buffer` — the same three steps `auto_resume` already
  used for exactly this case — and sets `buflisted`, matching what a `back` chat gets. Refusing
  instead would leave the restart case unreachable, which is the whole point.
- **It opens chat files and nothing else.** The check runs on the file's own content _before_ a
  buffer is created, so a rejected call leaves nothing behind. This is not fussiness about scope:
  a `file_path` that reaches `send_message` gets a `## User` section written into it, so accepting
  an ordinary source file would make sending a destructive edit of the user's work.
  `nvim_load_buffer` remains the way to read anything else.
- **Passing both `bufnr` and `file_path` is an error, on both sides of the wire.** Two names for
  one target is a sign the caller is confused about which chat it means, and quietly preferring
  one delivers into a chat nobody intended with nothing saying so. The advertised JSON Schema
  requires neither, since a `required` list naming two mutually exclusive keys reads as "pass
  both". `handlers/bufnr.lua`'s `resolve_chat_target` enforces it on the Lua side and
  `validation/schema.ts`'s `validateChatTarget` on the Node side — one function per side rather
  than one per tool, since the two tools disagree only about whether _neither_ is allowed
  (`nvim_get_buffer` falls back to the current buffer; a send has nothing to fall back to).
- **`from_bufnr` stays a bufnr**, and the asymmetry is deliberate: it names the _calling_ chat,
  whose number the system prompt restates every turn, so it is never stale.
- **The bufnr half of the prompt line is the cache-unstable half.** Closing or reopening the
  orchestrator changes it; so does `:VibingSetFileTitle`, which moves the path too. Each costs one
  #469 cache miss, accepted for a line that now survives a restart at all.

`ChatLocator.resolve_all` keeps an entry for a path it could not resolve, with no `bufnr`. Its
predecessor (`orchestration_link.resolve_bufnrs`) dropped those, which meant a worker whose
orchestrator was merely closed lost the prompt line entirely — the one case the path form exists
to serve.

**`bufnr` is a `0` that stays `0` on the send path.** `handlers/bufnr.lua` has two resolvers and
they differ in exactly this: `resolve` maps `0` to the current buffer, which is what the
annotation and highlight tools want, while `resolve_chat_target` hands it through. A send appends
a `## User` and starts a turn, so reading `0` as "whichever chat the user is sitting in" is the
same misdelivery the both-arguments refusal exists to prevent — and `nvim_get_buffer` advertises
`0` as the current buffer, so a model will try it here too. Passed through, `nvim_buf_get_lines`
still reads it as the current buffer while `view.get_chat_buffer(0)` refuses the send. Both
resolvers also treat an explicit JSON `null` as absent: `vim.json.decode` turns it into the truthy
`vim.NIL`, so a model spelling the unused argument as `null` would otherwise be told it named the
target twice.

**Under Lua/Node skew the read path now fails loudly**, which is the one place this differs from
`include_chat_status`. A Neovim too old to know `file_path` ignores it and answers for `bufnr or
0` — the current buffer — and that reads as a perfectly healthy transcript of the chat that was
asked for, reported `idle`. So `buf_get_lines` reports the buffer it actually read, and the MCP
handler refuses an answer that omits it whenever a `file_path` was passed. The send path needs no
equivalent: it errors outright when it can find no target.
