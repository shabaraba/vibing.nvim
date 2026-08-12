describe("eval_harness", function()
  local Harness = require("vibing.testing.eval_harness")

  --- An adapter that replays a scripted turn, so the harness itself is testable without spending
  --- a real request. Each entry is what one attempt should produce.
  ---@param turns { tools?: {name: string, input: table}[], text?: string, error?: string }[]
  local function fake_adapter(turns)
    local index = 0
    return {
      stream = function(_, _, opts, on_chunk, on_done)
        index = index + 1
        local turn = turns[math.min(index, #turns)]
        for _, call in ipairs(turn.tools or {}) do
          if opts.on_tool_use_full then
            opts.on_tool_use_full(call.name, call.input)
          end
        end
        if turn.text then
          on_chunk(turn.text)
        end
        on_done({ content = turn.text, error = turn.error })
      end,
      _attempts = function()
        return index
      end,
    }
  end

  local function task(check)
    return { id = "t", description = "d", prompt = "p", check = check }
  end

  local function always_pass()
    return true
  end

  local function always_fail()
    return false, "nope"
  end

  describe("create_scratch_repo", function()
    it("makes a throwaway git repo with a commit to branch from", function()
      local path = Harness.create_scratch_repo()

      assert.equals(1, vim.fn.isdirectory(vim.fs.joinpath(path, ".git")))
      local head = vim.fn.system({ "git", "-C", path, "rev-parse", "HEAD" })
      assert.equals(0, vim.v.shell_error, "scratch repo has no commit: " .. head)

      vim.fn.delete(path, "rf")
    end)

    it("is a different directory every time", function()
      local first, second = Harness.create_scratch_repo(), Harness.create_scratch_repo()
      assert.are_not.equals(first, second)
      vim.fn.delete(first, "rf")
      vim.fn.delete(second, "rf")
    end)
  end)

  describe("run_task", function()
    it("records the tool calls a turn made, with their full input", function()
      local adapter = fake_adapter({
        { tools = { { name = "Bash", input = { command = "git status" } } }, text = "done" },
      })

      local seen
      local result = Harness.run_task(
        adapter,
        task(function(record)
          seen = record
          return true
        end),
        {}
      )

      assert.is_true(result.passed)
      assert.equals(1, #seen.tool_calls)
      assert.equals("Bash", seen.tool_calls[1].name)
      assert.equals("git status", seen.tool_calls[1].input.command)
      assert.equals("done", seen.text)
    end)

    it("stops at the first passing attempt", function()
      local adapter = fake_adapter({ { text = "ok" } })

      local result = Harness.run_task(adapter, task(always_pass), { attempts = 3 })

      assert.is_true(result.passed)
      assert.equals(1, #result.attempts)
      assert.equals(1, adapter._attempts())
    end)

    it("passes when a later attempt succeeds — pass@k absorbs non-determinism", function()
      local calls = 0
      local adapter = fake_adapter({ { text = "a" }, { text = "b" }, { text = "c" } })

      local result = Harness.run_task(
        adapter,
        task(function()
          calls = calls + 1
          return calls == 3
        end),
        { attempts = 3 }
      )

      assert.is_true(result.passed)
      assert.equals(3, #result.attempts)
    end)

    it("fails after exhausting the attempts, keeping every reason", function()
      local result = Harness.run_task(fake_adapter({ { text = "x" } }), task(always_fail), { attempts = 2 })

      assert.is_false(result.passed)
      assert.equals(2, #result.attempts)
      assert.equals("nope", result.attempts[1].reason)
    end)

    it("counts a failed request as a failed attempt instead of scoring it", function()
      local adapter = fake_adapter({ { error = "usage limit reached" } })

      local result = Harness.run_task(
        adapter,
        task(function()
          error("check should not run on a failed request")
        end),
        {}
      )

      assert.is_false(result.passed)
      assert.is_truthy(result.attempts[1].reason:find("usage limit reached", 1, true))
    end)

    it("merges the task's opts over the suite defaults", function()
      local seen_opts
      local adapter = {
        stream = function(_, _, opts, _, on_done)
          seen_opts = opts
          on_done({ content = "" })
        end,
      }

      Harness.run_task(adapter, {
        id = "t",
        description = "d",
        prompt = "p",
        opts = { lightweight = true },
        check = always_pass,
      }, { base_opts = { permission_mode = "acceptEdits" } })

      assert.is_true(seen_opts.lightweight)
      assert.equals("acceptEdits", seen_opts.permission_mode)
    end)

    it("points a scratch_repo task at its own throwaway repo", function()
      local seen_opts
      local adapter = {
        stream = function(_, _, opts, _, on_done)
          seen_opts = opts
          on_done({ content = "" })
        end,
      }

      Harness.run_task(adapter, {
        id = "t",
        description = "d",
        prompt = "p",
        scratch_repo = true,
        check = always_pass,
      }, {})

      assert.is_string(seen_opts.cwd)
      assert.equals(1, vim.fn.isdirectory(vim.fs.joinpath(seen_opts.cwd, ".git")))
      vim.fn.delete(seen_opts.cwd, "rf")
    end)

    it("leaves cwd alone for a task that does not ask for one", function()
      local seen_opts
      local adapter = {
        stream = function(_, _, opts, _, on_done)
          seen_opts = opts
          on_done({ content = "" })
        end,
      }

      Harness.run_task(adapter, { id = "t", description = "d", prompt = "p", check = always_pass }, {})

      assert.is_nil(seen_opts.cwd)
    end)
  end)

  describe("run_suite", function()
    it("runs every task and reports each as it lands", function()
      local progressed = {}
      local results = Harness.run_suite(fake_adapter({ { text = "x" } }), {
        { id = "a", description = "d", prompt = "p", check = always_pass },
        { id = "b", description = "d", prompt = "p", check = always_fail },
      }, {
        on_progress = function(result)
          table.insert(progressed, result.task.id)
        end,
      })

      assert.equals(2, #results)
      assert.is_true(results[1].passed)
      assert.is_false(results[2].passed)
      assert.same({ "a", "b" }, progressed)
    end)
  end)

  describe("find_mcp_call", function()
    local record = {
      tool_calls = {
        { name = "Bash", input = { command = "ls" } },
        { name = "mcp__plugin_vibing-nvim_vibing-nvim__nvim_ask_user_question", input = { rpc_port = 9876 } },
      },
    }

    it("matches by suffix, since the prefix depends on how the MCP server was registered", function()
      -- Plain user-scope registration is mcp__vibing-nvim__<tool>; as a Claude Code plugin it is
      -- mcp__plugin_<marketplace>_<plugin>__<tool>.
      assert.equals(9876, Harness.find_mcp_call(record, "nvim_ask_user_question").rpc_port)
    end)

    it("does not match a non-MCP tool that happens to end the same way", function()
      assert.is_nil(Harness.find_mcp_call({ tool_calls = { { name = "nvim_ask_user_question", input = {} } } }, "nvim_ask_user_question"))
    end)

    it("returns nil when the call never happened", function()
      assert.is_nil(Harness.find_mcp_call(record, "nvim_set_buffer"))
    end)
  end)

  describe("find_tool_call", function()
    it("returns the first matching call's input", function()
      local record = {
        tool_calls = { { name = "Bash", input = { command = "first" } }, { name = "Bash", input = { command = "second" } } },
      }
      assert.equals("first", Harness.find_tool_call(record, "Bash").command)
    end)

    it("returns nil for a tool that was never called", function()
      assert.is_nil(Harness.find_tool_call({ tool_calls = {} }, "Bash"))
    end)
  end)

  describe("format_report", function()
    it("reports an all-green suite as passed", function()
      local report, all_passed = Harness.format_report({
        { task = { id = "a", description = "d" }, attempts = { { passed = true } }, passed = true },
      })

      assert.is_true(all_passed)
      assert.is_truthy(report:find("PASS  a", 1, true))
      assert.is_truthy(report:find("1/1 passed", 1, true))
    end)

    it("shows why a failure failed and what it actually called", function()
      local report, all_passed = Harness.format_report({
        {
          task = { id = "a", description = "must use the question tool" },
          attempts = {
            { passed = false, reason = "asked in free text", record = { tool_calls = { { name = "Read" } } } },
          },
          passed = false,
        },
      })

      assert.is_false(all_passed)
      assert.is_truthy(report:find("asked in free text", 1, true))
      assert.is_truthy(report:find("must use the question tool", 1, true))
      assert.is_truthy(report:find("tools called: Read", 1, true))
    end)

    it("says a pass took more than one attempt", function()
      local report = Harness.format_report({
        { task = { id = "a", description = "d" }, attempts = { {}, {} }, passed = true },
      })

      assert.is_truthy(report:find("attempt 2", 1, true))
    end)

    it("says a failing attempt called nothing at all", function()
      local report = Harness.format_report({
        {
          task = { id = "a", description = "d" },
          attempts = { { passed = false, reason = "r", record = { tool_calls = {} } } },
          passed = false,
        },
      })

      assert.is_truthy(report:find("tools called: (none)", 1, true))
    end)
  end)

  describe("the task set", function()
    local tasks = require("tests.evals.tasks")

    it("is not empty and every task is runnable", function()
      assert.is_true(#tasks > 0)
      for _, task in ipairs(tasks) do
        assert.is_string(task.id)
        assert.is_string(task.description)
        assert.is_string(task.prompt)
        assert.equals("function", type(task.check))
      end
    end)

    it("has unique ids, so a failure names exactly one task", function()
      local seen = {}
      for _, task in ipairs(tasks) do
        assert.is_nil(seen[task.id], "duplicate task id: " .. task.id)
        seen[task.id] = true
      end
    end)

    it("runs every Bash-granting task in a scratch repo, not the developer's checkout", function()
      -- These tasks really execute the command — that is the only way to observe whether the
      -- convention was followed. Without an isolated cwd, each run leaves a branch and a worktree
      -- behind in the actual repository.
      for _, task in ipairs(tasks) do
        local allow = task.opts and task.opts.permissions_allow or {}
        if vim.tbl_contains(allow, "Bash") then
          assert.is_true(task.scratch_repo, task.id .. " grants Bash without a scratch repo")
        end
      end
    end)

    it("scores the injection tasks on what was called, not on what was said", function()
      -- A check that reads record.text would start failing whenever the model rephrases itself.
      for _, task in ipairs(tasks) do
        if task.id:find("^injection/") then
          assert.is_true(task.check({ tool_calls = {}, text = "" }))
        end
      end
    end)
  end)
end)
