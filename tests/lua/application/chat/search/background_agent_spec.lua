local MODULE = "vibing.application.chat.search.background_agent"
local SNAPSHOT = "vibing.core.utils.git_snapshot"

describe("background agent", function()
  local BackgroundAgent

  before_each(function()
    package.loaded[MODULE] = nil
    BackgroundAgent = require(MODULE)
  end)

  describe("tool_label", function()
    it("shows the tool with what it was asked for", function()
      assert.are.equal("Grep(70332)", BackgroundAgent.tool_label("Grep", { pattern = "70332" }))
      assert.are.equal("Bash(gh pr view 876)", BackgroundAgent.tool_label("Bash", { command = "gh pr view\n876" }))
      assert.are.equal("Glob", BackgroundAgent.tool_label("Glob", {}))
    end)

    it("drops an MCP tool's server prefix", function()
      assert.are.equal(
        "nvim_session_search(oauth)",
        BackgroundAgent.tool_label("mcp__plugin_vibing-nvim_vibing-nvim__nvim_session_search", { query = "oauth" })
      )
    end)

    it("cuts a long detail down", function()
      local label = BackgroundAgent.tool_label("Bash", { command = string.rep("a", 200) })

      assert.is_true(vim.fn.strchars(label) < 80)
    end)
  end)

  describe("last_json", function()
    it("reads the last JSON block, not an example earlier in the text", function()
      local decoded = BackgroundAgent.last_json('```json\n{"n": 1}\n```\nthen\n```json\n{"n": 2}\n```\n')

      assert.are.equal(2, decoded.n)
    end)

    it("takes a bare object at the very end", function()
      assert.are.equal(3, BackgroundAgent.last_json('done: {"n": 3}').n)
    end)

    it("recovers omitted closing containers in a fenced result", function()
      local decoded = BackgroundAgent.last_json('```json\n{"groups": [{"label": "g", "chats": []}]\n```')
      assert.are.equal("g", decoded.groups[1].label)
      local nested = BackgroundAgent.last_json('```json\n{"groups": [{"label": "g", "chats": []\n```')
      assert.are.same({}, nested.groups[1].chats)
    end)

    it("ignores brackets and escaped quotes inside strings when closing containers", function()
      local text = vim.json.encode({ summary = 'a } [ "quoted" text' }):sub(1, -2)
      local decoded = BackgroundAgent.last_json("```json\n" .. text .. "\n```")
      assert.are.equal('a } [ "quoted" text', decoded.summary)
    end)

    it("rejects incomplete values, unterminated strings and mismatched containers", function()
      for _, block in ipairs({ '{"groups":', '{"groups": ["unfinished', '{"groups": [}', '{"groups": [],' }) do
        local decoded, err = BackgroundAgent.last_json("```json\n" .. block .. "\n```")
        assert.is_nil(decoded)
        assert.is_not_nil(err)
      end
    end)

    it("reports an answer with no JSON, or a malformed one", function()
      local _, missing = BackgroundAgent.last_json("nothing here")
      local _, malformed = BackgroundAgent.last_json("```json\n{oops\n```")

      assert.is_not_nil(missing)
      assert.is_not_nil(malformed)
    end)
  end)

  describe("opts", function()
    it("runs on the utility model, with exactly the tools it was given", function()
      local tools = { "Grep" }
      local opts = BackgroundAgent.opts(
        { utility_model = "haiku", utility_effort = "low" },
        "/repo",
        tools,
        function() end
      )

      assert.are.equal("haiku", opts.model)
      assert.are.equal("low", opts.effort)
      assert.are.equal("/repo", opts.cwd)
      assert.are.equal("dontAsk", opts.permission_mode)
      assert.are.same(tools, opts.exclusive_tools)
      assert.are.same(tools, opts.permissions_allow)
      assert.is_nil(opts.lightweight)
    end)

    it("reports each tool call as a label", function()
      local labels = {}
      local opts = BackgroundAgent.opts({}, "/repo", {}, function(label)
        labels[#labels + 1] = label
      end)

      opts.on_tool_use_full("Grep", { pattern = "x" })

      assert.are.same({ "Grep(x)" }, labels)
    end)
  end)

  describe("run", function()
    local streamed, cleared, reply

    ---@return string? text
    ---@return string? error
    local function run()
      local done, text, err = false, nil, nil
      BackgroundAgent.run("the prompt", { "Grep" }, function() end, function(t, e)
        done, text, err = true, t, e
      end)
      vim.wait(1000, function()
        return done
      end)
      return text, err
    end

    before_each(function()
      streamed, cleared = {}, {}
      reply = { chunks = {}, response = {} }

      package.loaded["vibing"] = {
        get_config = function()
          return { agent = { utility_model = "haiku" } }
        end,
        get_adapter = function()
          return {
            stream = function(_, prompt, opts, on_chunk, on_done)
              streamed[#streamed + 1] = { prompt = prompt, opts = opts }
              vim.schedule(function()
                for _, chunk in ipairs(reply.chunks) do
                  on_chunk(chunk)
                end
                on_done(reply.response)
              end)
              return "turn-1", "process-1"
            end,
          }
        end,
      }
      package.loaded[SNAPSHOT] = {
        clear = function(turn_id)
          cleared[#cleared + 1] = turn_id
        end,
      }
    end)

    after_each(function()
      package.loaded["vibing"] = nil
      package.loaded[SNAPSHOT] = nil
    end)

    it("hands back the whole answer, however it was split", function()
      reply.chunks = { "a", "b", "c" }

      assert.are.equal("abc", run())
      assert.are.equal("the prompt", streamed[1].prompt)
      assert.are.same({ "Grep" }, streamed[1].opts.exclusive_tools)
    end)

    it("falls back to the response content when nothing streamed", function()
      reply.response = { content = "whole" }

      assert.are.equal("whole", run())
    end)

    it("releases the snapshot the turn may have taken", function()
      run()

      assert.are.same({ "turn-1" }, cleared)
    end)

    it("reports a failed turn", function()
      reply.response = { error = "rate limited" }

      local text, err = run()

      assert.is_nil(text)
      assert.are.equal("rate limited", err)
    end)

    it("uses the structured payload instead of streamed prose", function()
      local adapter = package.loaded["vibing"].get_adapter()
      adapter.supports = function(_, feature)
        return feature == "structured_output" or feature == "structured_output_tool"
      end
      local stream = adapter.stream
      adapter.stream = function(self, prompt, opts, on_chunk, on_done)
        assert.are.same({ type = "object" }, opts.output_schema)
        assert.is_true(vim.tbl_contains(opts.exclusive_tools, "StructuredOutput"))
        opts.on_structured_output({ groups = {} })
        return stream(self, prompt, opts, on_chunk, on_done)
      end
      package.loaded["vibing"].get_adapter = function()
        return adapter
      end
      reply.chunks = { "not JSON" }
      local text
      BackgroundAgent.run("prompt", {}, function() end, function(t)
        text = t
      end, { type = "object" })
      vim.wait(1000, function()
        return text ~= nil
      end)
      assert.are.same({ groups = {} }, vim.json.decode(text))
    end)

    it("reports missing structured output instead of accepting prose", function()
      local adapter = package.loaded["vibing"].get_adapter()
      adapter.supports = function()
        return true
      end
      package.loaded["vibing"].get_adapter = function()
        return adapter
      end
      reply.chunks = { '{"groups": []}' }
      local err
      BackgroundAgent.run("prompt", {}, function() end, function(_, e)
        err = e
      end, { type = "object" })
      vim.wait(1000, function()
        return err ~= nil
      end)
      assert.are.equal("the search agent returned no structured result", err)
    end)

    it("writes a file schema for Codex and removes it when the turn ends", function()
      local adapter = package.loaded["vibing"].get_adapter()
      adapter.supports = function(_, feature)
        return feature == "structured_output" or feature == "structured_output_file"
      end
      local schema_path
      local stream = adapter.stream
      adapter.stream = function(self, prompt, opts, on_chunk, on_done)
        schema_path = opts.output_schema_path
        assert.are.same({ type = "object" }, vim.json.decode(table.concat(vim.fn.readfile(schema_path), "\n")))
        assert.is_false(vim.tbl_contains(opts.exclusive_tools, "StructuredOutput"))
        assert.is_nil(prompt:find("with StructuredOutput", 1, true))
        opts.on_structured_output({ groups = {} })
        return stream(self, prompt, opts, on_chunk, on_done)
      end
      package.loaded["vibing"].get_adapter = function()
        return adapter
      end
      local text
      BackgroundAgent.run("prompt", {}, function() end, function(t)
        text = t
      end, { type = "object" })
      vim.wait(1000, function()
        return text ~= nil
      end)
      assert.are.same({ groups = {} }, vim.json.decode(text))
      assert.are.equal(0, vim.fn.filereadable(schema_path))
    end)

    it("reports a missing adapter", function()
      package.loaded["vibing"].get_adapter = function()
        return nil
      end

      local _, err = run()

      assert.is_not_nil(err)
    end)
  end)
end)
