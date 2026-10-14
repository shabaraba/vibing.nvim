---@diagnostic disable: undefined-field
local Transcript = require("vibing.infrastructure.adapter.modules.claude_subagent_transcript")

describe("adapter.claude_subagent_transcript", function()
  describe("finding a subagent's own transcript", function()
    it("builds the documented path, with the project directory slugged", function()
      assert.equals(
        vim.env.HOME .. "/.claude/projects/-Users-x-work-repo/sess-1/subagents/agent-a1.jsonl",
        Transcript.path("/Users/x/work/repo", "sess-1", "a1")
      )
    end)
  end)

  describe("reading the answer back off disk", function()
    local dir

    before_each(function()
      dir = vim.fn.tempname()
      vim.fn.mkdir(dir, "p") -- mkdir-ok: rooted at vim.fn.tempname(), so it is this spec's alone
    end)

    local function write(name, lines)
      local path = dir .. "/" .. name
      vim.fn.writefile(lines, path)
      return path
    end

    it("returns the last assistant text, not the first", function()
      local path = write("t.jsonl", {
        vim.json.encode({ type = "assistant", message = { content = { { type = "text", text = "first" } } } }),
        vim.json.encode({ type = "user", message = { content = { { type = "text", text = "noise" } } } }),
        vim.json.encode({ type = "assistant", message = { content = { { type = "text", text = "last" } } } }),
      })
      assert.equals("last", Transcript.last_text(path))
    end)

    it("skips a tool_use-only assistant turn", function()
      local path = write("t.jsonl", {
        vim.json.encode({ type = "assistant", message = { content = { { type = "text", text = "answer" } } } }),
        vim.json.encode({ type = "assistant", message = { content = { { type = "tool_use", name = "Read" } } } }),
      })
      assert.equals("answer", Transcript.last_text(path))
    end)

    -- A half-written transcript is the normal state right after a process dies, so one unparseable
    -- line must not lose the lines around it.
    it("survives a malformed line", function()
      local path = write("t.jsonl", {
        vim.json.encode({ type = "assistant", message = { content = { { type = "text", text = "kept" } } } }),
        '{not json "assistant"',
      })
      assert.equals("kept", Transcript.last_text(path))
    end)

    it("returns nil for a file that is not there", function()
      assert.is_nil(Transcript.last_text(dir .. "/absent.jsonl"))
    end)

    it("returns nil when the transcript holds no assistant text at all", function()
      local path = write("t.jsonl", { vim.json.encode({ type = "user", message = { content = {} } }) })
      assert.is_nil(Transcript.last_text(path))
    end)

    -- The backwards scan prefilters on a substring, and a `user` entry quoting the word is exactly
    -- what a prefilter used as a decision would get wrong.
    it("does not mistake a user entry that mentions the word for an answer", function()
      local path = write("t.jsonl", {
        vim.json.encode({ type = "assistant", message = { content = { { type = "text", text = "real" } } } }),
        vim.json.encode({ type = "user", message = { content = { { type = "text", text = "ask the assistant" } } } }),
      })
      assert.equals("real", Transcript.last_text(path))
    end)
  end)

  describe("recovering a turn's leftovers", function()
    it("recovers nothing without a session id", function()
      -- No session id means no directory to look in, and guessing one reads another
      -- conversation's subagents.
      assert.same({}, Transcript.recover({ { task_id = "a1" } }, "/tmp", nil))
    end)

    -- "A subagent finished and here is nothing" is worse than staying quiet.
    it("drops a task whose transcript could not be read", function()
      assert.same({}, Transcript.recover({ { task_id = "nope" } }, "/tmp/absent", "sess-1"))
    end)

    it("recovers nothing from an empty list", function()
      assert.same({}, Transcript.recover({}, "/tmp", "sess-1"))
    end)

    -- The recovered entry names the task it answers, so the wake notice can subtract these from the
    -- outstanding set and ask only about the ones still running (#820). Nothing else identifies it:
    -- the answer text is the subagent's own prose and the list order is not a key.
    it("names the task each answer belongs to", function()
      local original = Transcript.last_text
      Transcript.last_text = function(path)
        return path:find("agent-a1", 1, true) and "what a1 concluded" or nil
      end
      local ok, recovered = pcall(
        Transcript.recover,
        { { task_id = "a1", description = "review reuse" }, { task_id = "a2" } },
        "/tmp/repo",
        "sess-1"
      )
      Transcript.last_text = original

      assert.is_true(ok)
      assert.equals(1, #recovered)
      assert.equals("a1", recovered[1].task_id)
      assert.equals("what a1 concluded", recovered[1].text)
      -- Naming the block is the chat layer's job, from the launch's own description.
      assert.is_nil(recovered[1].label)
    end)
  end)
end)
