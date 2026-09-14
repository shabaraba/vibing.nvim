# Usage Limits: Auto-Resume and Scheduled Requests

Moved out of `.claude/rules/features.md` so it is read when this path is touched rather than on
every request. The rule that stays always-loaded is the short list in that file.

## Auto-Resume on Usage Limit

When a turn is rejected because the plan's usage limit is exhausted, vibing.nvim can park the chat
and send a single continuation message once the limit resets. Opt-in via
`agent.auto_resume_on_limit.enabled` (default `false` — it spends tokens unattended).

Detection merges three signals in `lua/vibing/core/utils/rate_limit.lua`: the CLI's
`rate_limit_event` stream line (the **only** source of `resetsAt`), the `StopFailure` hook filtered
to `error_type = rate_limit` (confirms the turn died, no timestamp), and the error text as a
fallback. None of these payload shapes is officially documented, so every field is optional and a
schema change degrades the feature instead of breaking the stream.

### Which Channel Each Backend Has

The merge itself lives in `adapter/modules/rate_limit_detector.lua`, called identically by all four
adapters. It used to be written inline in `claude_cli.lua`, and that is the whole reason auto-resume
was a claude-only feature for so long: nothing downstream was claude-specific — the project limit
record, the scheduled re-send and the retry budget were already scoped per backend — but a codex or
grok chat that hit its provider's limit produced no `_rate_limit_info`, so `send_message.lua` took
the ordinary error branch and the chat simply stopped. Keeping detection in one shared module makes
"does this backend auto-resume?" a question about which channels its CLI offers.

That it stays that way is pinned in `tests/lua/infrastructure/adapter/stream_options_spec.lua`,
which drives a non-zero exit with limit wording on stderr through every backend `agents.lua`
registers and asserts `_rate_limit_info` came back. A new adapter joins that check by existing.

| Backend | stream event | `StopFailure` hook | error text | `resets_at`?          |
| ------- | ------------ | ------------------ | ---------- | --------------------- |
| claude  | ✅ yes       | ✅ yes             | ✅ yes     | ✅ stream event       |
| codex   | —            | —                  | ✅ yes     | ✅ stated in the text |
| copilot | —            | —                  | ✅ yes     | —                     |
| grok    | —            | —                  | ✅ yes     | —                     |

Codex exec's `ThreadEvent` stream (`thread.started` / `turn.*` / `item.*` / `error`) carries no
rate-limit event at all — codex 0.154 does have a `TokenCountEvent` with a `rate_limits` snapshot,
but only on the `app-server` protocol, not on `exec --json`. Neither codex, copilot nor grok
registers a `StopFailure` hook. So for those three the error text is the whole story, and it works
because all three exit non-zero when a turn dies (verified against codex 0.154, copilot 1.0.78),
which is what puts the CLI's own message in `response.error`.

### Reading the Reset Time Out of the Message

Codex prints when the limit lifts, so `core/utils/rate_limit_text.lua` reads it rather than
treating that backend as timeless. Its formatter (`protocol/src/num_format.rs` in codex 0.154)
appends `" or try again at "` plus `%-I:%M %p` when the reset is the same day, or
`%b %-d, %Y %-I:%M %p` when it is not — and `" or try again later."` when it has nothing to print.

This is a parse, never an inference. A phrasing the module does not recognise, and a dated form
with no year, both yield nil and leave the caller with exactly the behaviour below. Two rules are
worth keeping in mind when touching it:

- **A bare clock time is never rolled forward to tomorrow.** The CLI chooses that form precisely
  because the reset is today, so a time reading as already past means the limit has just lifted —
  and both readers already handle a past moment (`limit_state.get_active` reports the record
  inactive, `compute_delay` resumes promptly). Adding a day would park the chat for 24 hours on
  nothing but clock skew.
- **A time more than 8 days out is dropped**, matching the sanity ceiling `auto_resume.lua` applies
  to what it is handed, so an implausible parse degrades here instead of warning there.

The same failure arrives twice on the codex stream — once as `error`, once as `turn.failed` — and
`errorOutput` is concatenated with no separator, so `codex_event_processor.record_error` drops an
immediately repeated message. Without it the chat rendered both copies as one run-on sentence.

For copilot and grok, and for a codex message that printed no time, the two original consequences
still hold, and both remain by design rather than gaps worth closing with a guess:

- **Resume uses `fallback_delay_sec` (300s), not a real reset time.** `schedule()` says so in the
  notification (`"no reset time reported; this is a fallback retry"`), and `max_retries` bounds how
  often it can be wrong. For a five-hour window that retry will almost certainly be rejected again.
- **`.vibing/limit-state.json` is not written.** `LimitState.record` ignores a payload with no
  reset timestamp, since a record that cannot answer "is the limit still active?" would strand
  every later request. So the "park the _next_ chat pre-emptively" half of the feature needs a
  time: with one, a whole orchestrated fleet parks instead of each worker discovering the limit by
  being rejected; without one, only the chat that actually hit it parks and resumes.

Detection is gated on `response.error` rather than on the adapters' accumulated `error_output`.
`error` is set only when the process exited non-zero (or declared a failure in its result event),
whereas `error_output` also collects plain stderr — and every one of these CLIs writes harmless
warnings there. Matching on that instead would park a chat that had just answered fine.

`ERROR_TEXT_PATTERNS` carries both the prose spelling a CLI prints and the snake_case one an API
error type uses, because codex surfaces the raw provider envelope
(`{"error":{"type":"usage_limit_exceeded"}}`) as its `turn.failed` message. Every entry must name a
**time-windowed** limit: credit exhaustion reads similarly (grok says "out of credits" and "usage
balance exhausted") but never resets on its own, so matching it would schedule a resume guaranteed
to fail. "quota exceeded" is held out for the same reason — it is also what a filesystem reports
when a disk is full.

Pending resumes persist to `.vibing/pending-resume.json` and are re-armed on `setup()`, since a
five-hour reset usually outlives the Neovim session. Safeguards: `max_retries` (default 1) per
limit hit, never overwriting an unsent `## User` message, and an 8-day sanity ceiling on the reset
timestamp. Concurrently parked chats all fire at once by design. See `handbook/configuration.md` →
"Auto-Resume on Usage Limit".

### Giving Up

Before #698, a chat whose retry budget ran out just vanished from `.vibing/pending-resume.json`
with a `vim.notify` nobody was watching — the only way to learn why it had stopped was to go read
that file by hand (#692's postmortem hit this in a live parallel run: a chat sat with an unsent
message and no timer, and nothing in the buffer said so).

Both places that give up (`on_rate_limited`'s normal gate, and `fire()`'s defence-in-depth check
for a stale entry that outlives a restart) now call `auto_resume.announce_gave_up`, which:

- Appends `> auto-resume: retry budget exhausted (max_retries=N). Not resuming automatically.`
  directly into the chat's buffer, right before its trailing header, and saves the file. This is
  **not** a new request — nothing here calls `ChatBuffer:send_message()`, since that would spend
  a token exactly where the retry budget exists to stop that.
- Reads the chat's `orchestrated_by` frontmatter and, for each entry, forwards the identical line
  to that chat by path through `infrastructure/rpc/handlers/message.lua`'s `send_message`
  (`from_bufnr` = the gave-up chat, `queue_if_busy = true`), the same function
  `nvim_chat_send_message` uses. That forwarded delivery **does** start a turn on the orchestrator,
  deliberately: a chat that has given up on its own resume will never restart itself, which is the
  same "cannot leave this stop on its own" shape `completion_notifier` already delivers
  unconditionally for `asked_question` / `waiting_approval` / `error` — gating it behind
  `chat_notifications.enabled` would leave an orchestrated worker parked forever with nothing
  saying so. A chat with no `orchestrated_by` entries only gets its own buffer line.
- Fails soft per orchestrator: an unreachable parent path warns rather than raising, so one bad
  entry does not stop the chat's own notice line from being written.

**Implementation:** `adapter/modules/rate_limit_detector.lua` (the per-adapter seam),
`core/utils/rate_limit.lua` (channel normalization) and `core/utils/rate_limit_text.lua` (the
reset time a CLI stated in prose), `application/chat/auto_resume.lua` (scheduler),
`infrastructure/storage/pending_resume.lua` (persistence),
`infrastructure/rpc/handlers/rate_limit.lua` (StopFailure receiver), `bin/hooks/stop-failure.sh`.

## Scheduled Requests

A pending entry also has a `kind`. `auto_resume` (the default, and what a missing `kind` reads as)
sends the configured continuation prompt above. `scheduled` sends the chat's own unsent `## User`
body instead — the body is never copied into the pending-resume store, so it stays visible and
editable in the buffer while parked.

Scheduled requests come from three places: `:VibingSchedule [when]`, which works with no usage
limit on record at all as long as `when` is given (the no-argument form is the one that needs
`.vibing/limit-state.json`); a `<CR>` that lands while that file records a still-active limit
(excluding slash commands and a reply to a pending approval prompt, which always send
immediately); and a turn the limit actually rejected, whose message is written back into a fresh
unsent section instead of being discarded. The limit-aware `<CR>` and the rejected-turn
re-schedule are both governed by `agent.scheduled_requests.enabled` (default `true`);
`:VibingSchedule` is not, since the user armed it by hand.

`:VibingSchedule` and the limit-aware `<CR>` both save the chat file before arming the timer, but
differ on a save failure: `:VibingSchedule` refuses to schedule and nothing is sent — the message
stays unsent in the buffer for the user to retry; the `<CR>` interception instead fails open and
sends the message immediately, on the reasoning that a normal send is safer than silently sitting
on a message the user just tried to send. The rejected-turn path writes the text back into the
buffer the same way but leaves the actual save to whatever happens next (e.g. the buffer being
saved for an unrelated reason), rather than saving synchronously itself.

## The Retry Budget Is Shared, and Spent Before the Fixed Prompt Fires

`agent.scheduled_requests.max_retries` (default 3) bounds the fire → rejected → re-schedule loop.
Because the budget check is applied to the already-incremented retry count, the default only
permits **2** re-schedules after the first rejection. The next rejection falls through to
`auto_resume.on_rate_limited`, which re-checks the _same_ stored `retry_count` (already at 2)
against `auto_resume_on_limit.max_retries` — with both features at their defaults
(`scheduled_requests.max_retries = 3`, `auto_resume_on_limit.max_retries = 1`) that budget is
already spent, so the request is simply dropped. The fixed continuation prompt only fires if the
user has raised `auto_resume_on_limit.max_retries` above what the scheduled retries already
consumed.

## The Project Limit Record

`.vibing/limit-state.json` holds one record per project — the last observed reset time — and is
what lets a chat that never hit the limit itself still schedule instead of send. It is written
only when the payload carried a reset timestamp, and cleared on any successful response, so a
limit that lifts early is forgotten as soon as one request gets through. `:VibingCancelResume` also
clears this record (in addition to cancelling the entry), so "send now" — cancel, then `<CR>` —
actually sends instead of being re-parked by a stale record; if the limit is genuinely still in
force, the next rejected response re-records it.

**The record names the backend that hit the limit, and every reader is scoped to it.** The store
is per project but a limit belongs to one provider's plan, so an unscoped record parked codex
chats behind a claude limit — for the whole reset window, with no way to converse — and let a
successful codex turn clear the claude record out from under the chats waiting on it.

The two sides name the backend differently, and the difference is deliberate. **Writing** the
record — and clearing it on a successful turn — asks `factory.agent_id(adapter)` about the adapter
that actually ran, because "who was rejected" is a fact about the process, not about frontmatter a
user can edit while the turn is in flight. **Reading** it before a request exists
(`<CR>`, `:VibingSchedule`, `:VibingCancelResume`) has no adapter yet, so it predicts one with
`Modes.resolve_agent` (frontmatter `agent` > `config.adapter` > claude) — the same precedence
`send_message._resolve_adapter` applies a moment later.

A record with no `agent` field reads as claude's. Claude was the only backend detecting a limit
back when the field did not exist, so it is the only one that can have written such a record.
Codex now writes this file too, which is what makes the scoping above load-bearing rather than
theoretical. `:VibingCancelResume all` is the one unscoped clear left: it has no chat in hand, and
"forget everything" is the user saying so by hand.

**Implementation:** `infrastructure/storage/limit_state.lua` (project limit record),
`core/utils/when.lua` (time spec parser), plus the `kind` dispatch in
`application/chat/auto_resume.lua`.
