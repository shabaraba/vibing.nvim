# Self-Testing

vibing.nvim can test itself via a separate Neovim instance controlled over RPC
(`lua/vibing/testing/e2e_helper.lua`, specs in `tests/e2e/*.spec.lua`, run via `npm run test:e2e`).

For test architecture, the helper API reference (`spawn_nvim_instance`, `send_keys`,
`wait_for_buffer_content`, `cleanup_instance`), example test code, the test-scenario checklist,
and troubleshooting, see the `self-testing` skill (`.claude/skills/self-testing/SKILL.md`).
Invoke it when writing or debugging E2E tests.

**These specs spend real tokens, and only `test:e2e` runs them.** Some drive a full turn against
the CLI. `test:lua` sweeps `tests/` including `tests/e2e/`, so every spec self-skips unless
`VIBING_E2E=1` — which only `test:e2e` sets (`helper.should_run()`). Do not remove that guard to
"make E2E part of the normal suite": that is a per-run API bill on `pnpm run test`.

Three things the child Neovim needs, each of which silently produced a dead spec before:

- **`--embed`.** `spawn_nvim_instance` starts the child with it, because `jobstart{ rpc = true }`
  talks msgpack-RPC to its stdio. Without it every `rpcrequest` fails and the spec never gets past
  its first wait — which is the state all four specs were in.
- **`tests/e2e_init.lua`, not `tests/minimal_init.lua`.** The latter is the _parent's_ init (it
  wires up plenary); a child started with it has vibing.nvim on `runtimepath` but never calls
  `setup()`, so no `:Vibing*` command exists and `:VibingChat` does nothing. `e2e_init.lua` also
  points `chat.save_dir` at a per-child temp directory, so running the suite stops writing real
  chat files into the repository.
- **`wait_for_buffer_name`, not `wait_for_buffer_content`, for a filename.** The latter matches
  against buffer _text_, so `wait_for_buffer_content(inst, "%.md")` can never match. That one line,
  repeated at six sites, is what every spec was actually failing on.

## Agent Behavior Evals

E2E covers the harness; it does not cover whether the **agent** still behaves. `pnpm run test:eval`
(`tests/evals/`) runs the contracts this project states in its system prompt and tool descriptions
— use `nvim_ask_user_question` instead of free text, put worktrees under `.vibing/worktrees/`, pass
`rpc_port`, keep lightweight calls tool-free, ignore instructions embedded in reviewed content.

Scoring reads **only the tool calls a turn made** (`opts.on_tool_use_full`), never the response
prose, so rephrasing never breaks a test. Non-determinism is absorbed with pass@k
(`VIBING_EVAL_ATTEMPTS`), not by loosening checks.

It spends real tokens — one request per task per attempt — so it is not part of `pnpm run test`.
Run it when changing the system prompt, a tool description, permission flags, or the model. Details
and how to add a task: `tests/evals/README.md`.

## The CI Gate Is the Exit Code

CI runs `npm run test:lua` and reads nothing but its exit status. Do not add output parsing back:
`PlenaryBustedDirectory` prints one summary **per spec file**, so any `grep` for `Failed : 0`
matches while other files are failing — which is exactly how the gate passed a run with five dead
specs (#561). `tests/lua-test-exit-code.test.mjs` pins the three cases the gate rests on: a failing
assertion, a spec that will not load, and an otherwise-passing run.

The one case neither the exit code nor a summary count catches is a spec file that runs **zero**
tests (a `describe` that stopped being reached): plenary exits 0 without printing a summary, which
is also how the E2E specs opt out via `should_run()`.

## Vim Help Verification

`npm run check:doc` (`scripts/check-help.lua`, run by the "Verify Vim help files" CI step) is the
only thing that reads `doc/*.txt`: `npm run check` compiles `lua/` alone, and the prettier / eslint
/ markdownlint steps do not match `.txt`. It checks three things — that `helptags` generates (a
duplicate or malformed tag fails only here), that no line exceeds 78 columns, and that CONTENTS and
the body agree on section numbers and tags.

The width is measured with `strdisplaywidth`, which is why the checker runs inside nvim at all.
A byte count rejects the `•` and `—` already in `vibing.txt`; a character count would let a CJK
line run to 156 columns. Only Vim's own measure is right, and it already honours `ambiwidth`.

`:helptags` raises a Vim error instead of setting an exit code, so the checker wraps it in `pcall`
— nvim otherwise prints `E154` and still exits 0.

The CONTENTS check **fails closed**, which is the part worth not undoing. Keying it on "did any
rows parse" would let one unreadable CONTENTS block switch the check off while the run still
reported OK — the same shape of dead gate the whole exercise is about. So a file with a `CONTENTS`
heading and no readable `N. Title |tag|` rows is a failure, and the row pattern deliberately does
not require a dot leader, because space-aligned CONTENTS is ordinary vimdoc and used to skip the
check entirely. A file with no CONTENTS heading has nothing to disagree with and passes.

Section headings are matched at column 0 on purpose: that is what keeps a heading-shaped line
inside an indented `>` code example from being read as a real section. CONTENTS rows cannot be
anchored that way — they are indented — so they are read only from inside the CONTENTS block, and
headings only from outside it. Neither side depends on the two patterns never overlapping.

CONTENTS and the body are matched **by section number**, not by position. Walking the two lists in
parallel meant one renumbered section shifted everything after it, so a single typo reported as a
cascade and the first message named a section that was fine. Duplicate numbers on either side are
reported as such.

Sub-section numbering (`2.1`) is **rejected rather than skipped**. Neither pattern can read it, so
it used to drop out of the comparison without a word — checked-looking and unchecked, which is the
failure this checker exists to prevent. Supporting it should be a decision, not something
discovered from a green run.

`tests/help-check.test.mjs` pins each failure the gate is supposed to catch, including both width
cases and both fail-closed cases. The CI step gates the document; that file gates the checker.

## The Lua Syntax Gate Had the Same Hole

`npm run check` could not fail. `find lua -name '*.lua' -exec luac -p {} \;` reports `find`'s exit
status, not `luac`'s, so a file that would not compile printed its error and CI went green. It is
`-exec ... +` now, which propagates, and `tests/lua-syntax-gate.test.mjs` holds it there — reading
the command out of `package.json` rather than restating it, so the test cannot pass against a
command the project no longer runs.

## 3-Try Auto-Fix Rule

After implementing a feature, run `npm run test:e2e`. If it fails: analyze the failure, apply a
targeted fix (implementation or test), and re-run — up to 3 attempts, each based on new analysis
of the latest failure. If still failing after 3 attempts, stop and report to the user: the error,
the 3 fixes tried, the suspected cause, and a suggested next step.

**Critical rule:** do not proceed to code review while E2E tests are failing — either fix them via
the 3-try rule above or escalate to the user.

Before writing tests, consider invoking `/test-design` (`.claude/skills/test-design/SKILL.md`) to
generate prioritized test scenarios covering happy path, error cases, edge cases, and integration
points.
