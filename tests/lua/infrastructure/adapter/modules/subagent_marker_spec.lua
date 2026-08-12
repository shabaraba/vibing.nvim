describe("subagent_marker", function()
  local marker = require("vibing.infrastructure.adapter.modules.subagent_marker")

  -- Verbatim tail of a real Agent tool result.
  local REAL_RESULT = "PINEAPPLE\nagentId: ab2e2379a4f9c8c52 (use SendMessage with to: "
    .. "'ab2e2379a4f9c8c52', summary: '<5-10 word recap>' to continue this agent)"

  it("records the agent id an Agent call left behind", function()
    local out = marker.for_tool_result("Agent", { subagent_type = "general-purpose" }, REAL_RESULT)
    assert.equals("\n<!-- subagent: ab2e2379a4f9c8c52 type=general-purpose -->\n", out)
  end)

  it("accepts the legacy Task name the CLI used before v2.1.63", function()
    local out = marker.for_tool_result("Task", { subagent_type = "explorer" }, REAL_RESULT)
    assert.is_truthy(out:find("ab2e2379a4f9c8c52", 1, true))
  end)

  it("records nothing for a one-shot agent that returned no id", function()
    -- Built-in Explore/Plan agents cannot be resumed and report no agentId.
    assert.equals("", marker.for_tool_result("Agent", { subagent_type = "Explore" }, "Found 3 files."))
  end)

  it("records nothing for tools that are not subagent launchers", function()
    assert.equals("", marker.for_tool_result("Bash", {}, REAL_RESULT))
    assert.equals("", marker.for_tool_result(nil, {}, REAL_RESULT))
  end)

  it("survives a missing subagent_type rather than dropping the id", function()
    local out = marker.for_tool_result("Agent", {}, REAL_RESULT)
    assert.equals("\n<!-- subagent: ab2e2379a4f9c8c52 type=unknown -->\n", out)
  end)

  it("ignores a non-string result", function()
    assert.equals("", marker.for_tool_result("Agent", {}, nil))
    assert.equals("", marker.for_tool_result("Agent", {}, 42))
  end)

  describe("strip", function()
    it("removes the markers so a fork does not offer agents it cannot reach", function()
      local body = "## User\n\nhi\n<!-- subagent: aaa111 type=general-purpose -->\n## Assistant\n"
      local out = marker.strip(body)

      assert.is_nil(out:find("subagent:", 1, true))
      assert.is_truthy(out:find("## User", 1, true))
      assert.is_truthy(out:find("## Assistant", 1, true))
    end)

    it("removes every one of them", function()
      local body = marker.format("aaa111", "x") .. "text" .. marker.format("bbb222", "y")
      assert.is_nil(marker.strip(body):find("subagent:", 1, true))
    end)

    it("leaves a body without markers alone", function()
      assert.equals("## User\n\nhi\n", marker.strip("## User\n\nhi\n"))
    end)

    it("survives a nil body", function()
      assert.equals("", marker.strip(nil))
    end)
  end)

  describe("in the event processor", function()
    local processor = require("vibing.infrastructure.adapter.modules.cli_event_processor")

    local function run(display_mode)
      local chunks = {}
      local context = {
        output = {},
        errorOutput = {},
        onChunk = function(text)
          table.insert(chunks, text)
        end,
        _cached_display_mode = display_mode,
      }

      processor.processLine(
        vim.json.encode({
          type = "assistant",
          message = {
            role = "assistant",
            content = {
              {
                type = "tool_use",
                id = "toolu_1",
                name = "Agent",
                input = { subagent_type = "general-purpose" },
              },
            },
          },
        }),
        context
      )
      processor.processLine(
        vim.json.encode({
          type = "user",
          message = {
            role = "user",
            content = { { type = "tool_result", tool_use_id = "toolu_1", content = REAL_RESULT } },
          },
        }),
        context
      )
      vim.wait(50, function()
        return false
      end)

      return table.concat(chunks, "")
    end

    it("writes the marker into the chat text", function()
      assert.is_truthy(run("full"):find("<!-- subagent: ab2e2379a4f9c8c52 type=general-purpose -->", 1, true))
    end)

    it("still writes it when the result itself is truncated for display", function()
      -- The agentId sits at the END of the result, which "compact" mode cuts off — so the marker
      -- has to be built from the raw text, not from what gets rendered.
      local text = run("compact")
      assert.is_truthy(text:find("<!-- subagent: ab2e2379a4f9c8c52", 1, true))
    end)
  end)
end)
