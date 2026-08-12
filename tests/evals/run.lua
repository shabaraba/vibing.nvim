--- Entry point for `pnpm run test:eval`.
---
--- Runs every eval task against the real CLI and exits non-zero if any contract broke. This costs
--- real tokens — one request per task, per attempt — so it is deliberately not part of
--- `pnpm run test` and not wired into CI on every push.
---
--- Env:
---   VIBING_EVAL_ATTEMPTS  pass@k, default 1
---   VIBING_EVAL_MODEL     model to evaluate, default haiku (cheap; raise it when a contract
---                         failure looks model-dependent rather than prompt-dependent)
---   VIBING_EVAL_ONLY      Lua pattern; only run tasks whose id matches

local Harness = require("vibing.testing.eval_harness")

require("vibing").setup({
  mcp = { enabled = true },
  permissions = { mode = "acceptEdits" },
})

local adapter = require("vibing.infrastructure.adapter.claude_cli"):new({
  agent = { default_model = os.getenv("VIBING_EVAL_MODEL") or "haiku" },
})

local tasks = require("tests.evals.tasks")

local only = os.getenv("VIBING_EVAL_ONLY")
if only then
  tasks = vim.tbl_filter(function(task)
    return task.id:find(only) ~= nil
  end, tasks)
end

if #tasks == 0 then
  io.stderr:write("No eval tasks matched\n")
  os.exit(1)
end

local attempts = tonumber(os.getenv("VIBING_EVAL_ATTEMPTS") or "") or 1

io.write(string.format("Running %d eval task(s), up to %d attempt(s) each\n\n", #tasks, attempts))

local results = Harness.run_suite(adapter, tasks, {
  attempts = attempts,
  base_opts = {
    permissions_allow = { "Read", "Glob", "Grep" },
    permission_mode = "acceptEdits",
    -- A real chat always has one, and the system prompt tells the model to echo it back as the
    -- chat_bufnr argument. Without it the model cannot fill in a required argument and falls back
    -- to free text — which would fail the ask_user_question tasks for a harness reason rather than
    -- a contract reason.
    chat_bufnr = vim.api.nvim_create_buf(false, true),
  },
  on_progress = function(result)
    -- Print as they land: a full suite is minutes of real requests, and a silent terminal for
    -- that long reads like a hang.
    io.write(string.format("%s  %s\n", result.passed and "PASS" or "FAIL", result.task.id))
    io.flush()
  end,
})

local report, all_passed = Harness.format_report(results)
io.write("\n" .. report .. "\n")

os.exit(all_passed and 0 or 1)
