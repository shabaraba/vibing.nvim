# Testing

- **E2E specs spend real tokens and only `test:e2e` runs them.** `test:lua` sweeps `tests/`
  including `tests/e2e/`, so every spec self-skips unless `VIBING_E2E=1` (`helper.should_run()`).
  Do not remove that guard.
- **Anything depending on a CLI turn uses `wait_for_assistant_turns` / `_text` / `wait_for_response`,
  never `wait_for_buffer_content`.** `## … Assistant` is written whether the turn answered or died
  — `send_message.lua` appends `**Error:**` under that same header — so waiting for the header
  asserts nothing. The error pattern lives once, in `e2e_helper.lua`.
- **Agent behavior evals are separate from E2E.** `npm run test:eval` (`tests/evals/`) checks the
  contracts stated in the system prompt and tool descriptions. Scoring reads **only the tool calls
  a turn made** (`opts.on_tool_use_full`), never the prose, so rephrasing never breaks a test;
  non-determinism is absorbed with pass@k (`VIBING_EVAL_ATTEMPTS`), not by loosening checks. Run it
  after changing the system prompt, a tool description, permission flags, or the model.
  `tests/evals/README.md`.
- **3-try auto-fix rule.** After implementing a feature, run `npm run test:e2e`. On failure:
  analyze, apply one targeted fix, re-run — up to 3 attempts, each from fresh analysis. After 3,
  stop and report the error, the fixes tried, the suspected cause and a next step. **Do not proceed
  to code review while E2E is failing.**

Writing or debugging E2E specs is the `self-testing` skill (helper API, child-Neovim requirements,
troubleshooting). Designing the scenarios first is `test-design`. The CI gates themselves — and the
ways each has silently stopped failing — are the `ci-gates` skill.
