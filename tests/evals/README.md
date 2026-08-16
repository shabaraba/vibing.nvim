# Agent behavior evals

`tests/e2e/` checks that the **harness** works — a buffer opens, a keystroke lands, a response
arrives. Nothing there checks that the _agent_ behaves: that a change to the system prompt or to a
tool description didn't quietly stop the model from calling `nvim_ask_user_question`, or from
putting worktrees where this project puts them. That gap is what these evals cover.

```bash
pnpm run test:eval
```

**This costs real tokens.** One CLI request per task, per attempt. It is deliberately not part of
`pnpm run test` and not wired into every CI push — run it when you touch the system prompt, a tool
description, the permission flags, or the model.

## What it observes

Only one thing: **which tools were called, with what arguments.** Scoring never reads the response
prose — a check that asserted on wording would fail every time the model rephrased itself, which
teaches you to ignore the suite. `on_tool_use_full` on the adapter delivers the raw tool input, so
a check can assert on `rpc_port`, a full Bash command, or a file path.

Non-determinism is handled with pass@k rather than by loosening the checks: a task passes if any
attempt passes, and the report says which attempt it took.

## Environment

| Variable               | Default | Meaning                                                              |
| ---------------------- | ------- | -------------------------------------------------------------------- |
| `VIBING_EVAL_ATTEMPTS` | `1`     | k in pass@k                                                          |
| `VIBING_EVAL_MODEL`    | `haiku` | Model under evaluation. Raise it if a failure looks model-dependent. |
| `VIBING_EVAL_ONLY`     | —       | Lua pattern; run only tasks whose id matches                         |

```bash
VIBING_EVAL_ONLY=injection pnpm run test:eval
VIBING_EVAL_ATTEMPTS=3 VIBING_EVAL_MODEL=sonnet pnpm run test:eval
```

## What it actually runs

Three tasks grant real `Bash` and really execute what the model decides to run — that is the only
way to observe whether the worktree convention was followed, or whether an injected instruction was
obeyed. Those tasks are marked `scratch_repo = true` and run with `cwd` pointed at a fresh throwaway
git repo under `$TMPDIR`, never your checkout. Without that, every run left a real `eval-check`
branch and worktree behind in the repository (it did, once, before this was fixed).

A task that grants Bash without `scratch_repo` fails `eval_harness_spec.lua`, so the isolation
cannot be forgotten when adding one.

## Reading a failure

```text
FAIL  ask_user_question/uses_the_mcp_tool
      選択肢を出す場面ではnvim_ask_user_questionを使う
      attempt 1: asked in free text instead of calling nvim_ask_user_question
      tools called: ToolSearch
```

The "tools called" line is usually the whole diagnosis. Before concluding the model regressed,
check the harness gives the model what a real chat gives it — `base_opts` in `run.lua` supplies
`chat_bufnr` for exactly this reason, because without it the model cannot fill in a required
argument and falls back to prose, which looks identical to a genuine contract failure.

## Adding a task

Append to `tasks.lua`. The bar for a new task:

- The check decides from `record.tool_calls` alone.
- It encodes a contract this project actually states somewhere — a system prompt line
  (`cli_command_builder.lua`), a tool description (`claude-plugin/mcp-server/src/tools/`), or a documented
  convention. If nothing states it, the eval is testing a hope, not a regression.
- Its id is unique and reads as `area/what-it-asserts`.

`eval_harness_spec.lua` covers the harness itself with a scripted fake adapter, so it runs in the
ordinary suite and costs nothing.
