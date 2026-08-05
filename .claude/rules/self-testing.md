# Self-Testing

vibing.nvim can test itself via a separate Neovim instance controlled over RPC
(`lua/vibing/testing/e2e_helper.lua`, specs in `tests/e2e/*.spec.lua`, run via `npm run test:e2e`).

For test architecture, the helper API reference (`spawn_nvim_instance`, `send_keys`,
`wait_for_buffer_content`, `cleanup_instance`), example test code, the test-scenario checklist,
and troubleshooting, see the `self-testing` skill (`.claude/skills/self-testing/SKILL.md`).
Invoke it when writing or debugging E2E tests.

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
