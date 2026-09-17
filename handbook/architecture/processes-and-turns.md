# Processes and Turns

Detail behind `.claude/rules/architecture.md` → "Concurrent Execution, Fork and Subagent Chat",
whose session-keying sentence is the invariant this page is the reasoning for. A CLI process and a
request/response exchange are two things, and until #774 they shared one identifier called
`handle_id`, because one process served exactly one turn and the two coincided. #775 gave them
separate values; #776 gave them separate names and separate registries.

## Why they were split before anything needed them apart

Issue #774 wants one resident `claude` process per chat, serving many turns over an open stdin.
The measured win is per-turn latency (967–1065ms to the first event with a process per turn,
332–349ms from the second turn of a resident one) and an approval that answers in place instead of
killing the process and restarting it with a synthesized "I approved the X tool" message.

None of that was in #775/#776. What those brought was only the split, on the oneshot transport,
because **21 distinct consumers had been written against an identifier that meant two things**, and every
one of them had to be asked which it meant before the answer could start to differ. Doing that in
the same change as the transport would have made every regression ambiguous: a wrong diff could
have come from the new process model or from a key that had silently changed meaning.

The split is therefore observable only in one place — the child environment now carries
`VIBING_PROCESS_ID` instead of `VIBING_HANDLE_ID` — and everything else is internal.

## Which id each consumer takes, and what going wrong looks like

**Process-keyed.** The adapter's `_processes` table and everything `kill_tree` reaches; the
SessionManager (`--resume <id>` names a conversation the _process_ holds open); the child's
`VIBING_PROCESS_ID`; `ChatBuffer._current_process_id`.

**Turn-keyed.** Both diff baselines (`git_snapshot` and the `request_diff` fallback) and the git ref
`refs/worktree/vibing/<turn_id>`; `worktree_binding`'s pending observation; the
`.vibing/patches/*.patch` filename suffix; `response._turn_id`, which is what
`_handle_response`'s staleness check compares; the chunk staleness filter in `append_chunk`; the
parked rate-limit failure; the per-turn frontmatter in `permission.lua`'s `active_opts_by_turn`.

The direction of the naming was decided by what a missed site does, not by how many sites there
are. During the split `handle_id` kept meaning _turn_, which is what most consumers wanted, so a
missed site handed a turn id to something expecting a process: `_processes[turn_id]` is nil, so a
cancel silently does nothing and `get_session_id` returns nil, and the next turn starts a new
session. Loud. Had `handle_id` been redefined as the process instead, a missed site would have
handed a process id to `ensure_baseline`, which early-returns when a session already exists for
that key — so turn 2 would diff against turn 1's tree and `### Modified Files` would be quietly
wrong. That is the silent-loss shape `git_snapshot.lua`'s own comments exist to prevent. The name
itself is gone now: every consumer says `turn_id`, and `handle_id` appears nowhere in `lua/`.

The two minters live in `lua/vibing/core/utils/identity.lua` and emit the same shape on purpose:
nothing may parse an id to learn its kind, because that would be a convention with no invariant
behind it.

## Why the id alphabet moved into `core/utils/identity.lua`

Both ids have to survive `[^A-Za-z0-9_]` deletion unchanged, for two unrelated reasons: the process
id is interpolated into a JSON request by `bin/hooks/*.sh` after exactly that substitution, and the
turn id names a git ref and a patch filename, both of which sanitize as well. Before the split that
rule was described in a comment in `cli_runtime.lua` and independently re-implemented in
`git_snapshot.sanitize` and in `send_message`'s filename suffix, and **nothing checked the shell
against any of them**. `tests/lua/core/utils/identity_spec.lua` now reads the character class and
the params key back out of both scripts and compares them to the Lua constants, so a rename on
either side fails the build rather than silently breaking hook attribution — which no unit test
could have seen, since the shell is not exercised by `test:lua`.

The hex format is load-bearing for the same reason it always was: LuaJIT renders a large `hrtime`
double as `2.64e+15`, and both `.` and `+` are in the deleted class, so two ids minted in the same
millisecond could collapse onto one sanitized value.

## The hook can only ever name a process

`VIBING_PROCESS_ID` is fixed when the child is spawned. That is not an implementation choice — an
environment variable cannot carry a per-turn value to a process that outlives the turn. So the turn
is never on the wire: `rpc/hook_scope.lua` resolves it in-editor, at the instant the hook arrives,
as the turn that process currently has open.

That module exists because `permission.lua` had been deriving the identity **three times per call
with two different policies**: once for the frontmatter opts, once inside `cancel_and_deny`, and
once more to pick a diff baseline key. They agreed only because `cli_adapter.stream()` populated
both tables in the same breath — an accident, not a guarantee — and on one input they disagreed.

`get_active_opts` fell back to the sole registered entry when the id was **present but unmatched**,
where the registry returned nil for the same input. So a hook arriving late, from a turn that had
already closed, had another chat's `allow` / `deny` / `:once` lists applied to its decision:
the #667 failure through a door #667 did not close. `hook_scope.of` now returns nil there, and
`build_permission_config` falls through to the global config, which is the fail-safer of the two
answers. A test pins it.

The one guess that survives is for a hook that named **no** process at all, and only when exactly
one turn is open. "A registered process is a running turn" stopped being true with #777 — a resident
process stays registered between turns — but the guess reads the _turn_ table, which still holds
only open turns, so "exactly one entry" still means "there is no other candidate". It is named
`sole_open()` rather than open-coded so there is one place to delete if a hook ever gains a way to
name its own turn; an environment variable never will.

## Two registries, because the split line is the id split

`active_stream_registry.lua` held five things and was really holding two, so #776 cut it where the
ids were already cut:

- **`process_registry.lua`** — keyed by process. The `--resume` session the process holds, the chat
  it serves, the adapter that can kill it, and `active_turn_id`.
- **`turn_registry.lua`** — keyed by turn, each entry holding a _reference_ to its process entry
  rather than a copy of its fields, so `adapter` / `chat_bufnr` / `session_id` have one home and
  cannot drift. It requires `process_registry`; the dependency never runs the other way, and
  `open` / `close` are the only writers of `active_turn_id`.

Two of the five moved sides, and both are bug fixes paid for by the split rather than behaviour
changes:

- **`find_other_active_for_session` → `process_registry.find_other_holding_session`.** The question
  is who _holds_ the session, not who is running. A resident process keeps its `--resume <id>`
  between turns, so asked of turns, a second process could attach to the same transcript the moment
  the first went idle — the corruption #756 refuses.
- **`find_other_active_for_worktree` → `turn_registry.find_other_writing_in`.** This one must stay
  per turn. The window it guards runs from a baseline to its `clear()`, which is a turn's window;
  asked of processes, two resident processes in one repository would make every chat overlap every
  other one permanently, every turn would fall back to `request_diff`, and the #625 snapshot
  mechanism would never be used again.

`turn_registry.get` also lost the nil fallback the old `get` carried; a caller with no id asks
`sole_open()` and says so. That is what keeps `git_snapshot`'s TTL sweep honest: inheriting the
fallback would report every stale baseline as still open whenever one turn happened to be running,
stopping the sweep and leaving `refs/worktree/vibing/` to grow without bound. The one call site
that could pass nil, `ChatBuffer:is_responding()`, already guarded it.

## `_capture_baselines` now declines an unresolvable turn

Previously a hook whose id matched nothing still took a baseline filed under that raw id. Nothing
ever cleared it, because `clear()` is only reached through a response — so each one left a
`refs/worktree/vibing/<id>` behind, collected only by the TTL sweep. It now takes no baseline at
all. This is a deliberate behaviour change and the only one in the split; it is strictly a
reduction in leaked state, and the case it fires on is a straggler tool call from a process that
has already been killed.

## What the resident transport did with the three things #775 left owed

All three are settled by #777, and none of them needed the separate fix it looked like they would.
They were owed because the answer depended on how a turn is delimited, and once that is a `result`
event the shape falls out:

- **`subagent_count`** is per turn entry, and a duplex turn opens a fresh entry — so it starts at 0
  by construction, and the previous turn's count is dropped by the `close` in `finish`. The failure
  it was guarding against (a `Task` whose `tool_result` never lands becoming a permanent
  contribution to `total_subagent_count()`, throttling every chat through
  `concurrency.at_capacity()`) needs only that the turn is always closed — including when the
  process dies mid-turn, which `duplex_routing.exit_handler` does.
- **`active_opts_by_turn`** is set by `cli_adapter.stream()`, before the transport branch, and a
  duplex turn is a `stream()` call like any other. Turn N+1 therefore cannot run under turn N's
  `permission_mode`.
- **`event_context` is per turn; the decoder's parse state is per process.** The split is one line:
  `duplex_stream` hands each turn's context the _process's_ `decoder_state` table. Everything else
  on the context — `tokenUsage`, `cliInfo`, `resultErrors`, `output` — is created fresh per turn and
  cut on the `result` event, which is exactly the boundary #775 said it could not guess.

Between turns the process is still talking (`active_goal` and `autocompact_state` arrive before the
first turn even starts), so there is an idle context per process whose only job is to let a
`session` event reach the SessionManager. The decoder ignores types it does not know, so everything
else there costs nothing.

`sole_open()` is still here. A resident process can now name its own turn, but the hook still
cannot: `VIBING_PROCESS_ID` is fixed at spawn, so a hook that names no process at all has no other
candidate to offer. What changed is that "a registered process is a running turn" is no longer true
— `process_registry.get(id)` can return an entry whose `active_turn_id` is nil — and `sole_open()`
reads the _turn_ table, which still holds only open turns. The one call that would have broken,
`_capture_baselines`, already declines an unresolvable turn.

## What is still owed

Both are deferred because they are wide mechanical changes that every branch stacked on this one
would have to absorb, and neither depends on the transport:

- **`stream()` returns the two ids positionally**, so `local id = adapter:stream(...)` compiles,
  yields the turn, and `cancel(id)` is then a silent no-op. The typed `Vibing.RequestIds` table the
  adapter already builds internally is what should cross the seam; that changes the adapter contract
  in `base.lua` and every conformance spec.
- **`cancel(nil)` means "kill every process this adapter owns."** The hazard is real — one adapter
  instance is shared between a chat's stream and the lightweight `execute()` calls — and is
  currently paid for with a guard at the one call site that can reach it. Splitting `cancel_all()`
  out and making `cancel(process_id)` require its argument removes the special case; it is deferred
  because `init.lua`, `base.lua` and five specs name the nil form.
