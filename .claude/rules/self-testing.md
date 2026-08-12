# Self-Testing

vibing.nvim can test itself via a separate Neovim instance controlled over RPC
(`lua/vibing/testing/e2e_helper.lua`, specs in `tests/e2e/*.spec.lua`, run via `npm run test:e2e`).

For test architecture, the helper API reference (`spawn_nvim_instance`, `send_keys`,
`wait_for_buffer_content`, `cleanup_instance`), example test code, the test-scenario checklist,
and troubleshooting, see the `self-testing` skill (`.claude/skills/self-testing/SKILL.md`).
Invoke it when writing or debugging E2E tests.

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
