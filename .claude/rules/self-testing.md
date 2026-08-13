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
