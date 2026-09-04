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

Pending resumes persist to `.vibing/pending-resume.json` and are re-armed on `setup()`, since a
five-hour reset usually outlives the Neovim session. Safeguards: `max_retries` (default 1) per
limit hit, never overwriting an unsent `## User` message, and an 8-day sanity ceiling on the reset
timestamp. Concurrently parked chats all fire at once by design. See `handbook/configuration.md` →
"Auto-Resume on Usage Limit".

**Implementation:** `application/chat/auto_resume.lua` (scheduler),
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

A record with no `agent` field reads as claude's, since claude is the only backend that reports a
rate limit (`claude_cli.lua`) and so the only one that could have written one.
`:VibingCancelResume all` is the one unscoped clear left: it has no chat in hand, and "forget
everything" is the user saying so by hand.

**Implementation:** `infrastructure/storage/limit_state.lua` (project limit record),
`core/utils/when.lua` (time spec parser), plus the `kind` dispatch in
`application/chat/auto_resume.lua`.
