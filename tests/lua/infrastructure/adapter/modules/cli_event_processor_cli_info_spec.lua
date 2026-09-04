--- What the stream says about the process that ran the turn.
---
--- The CLI's version, its tool and MCP-server counts, and whether the conversation was compacted
--- exist only as `system` events and die with the process. `prefix_rewrite.lua` has no other
--- source for any of them, so a break here silently degrades every later turn's diagnosis to
--- "no likely cause found".
describe("cli_event_processor cli info", function()
  local processor = require("vibing.infrastructure.adapter.modules.cli_event_processor")

  local function new_context()
    return { output = {}, errorOutput = {}, cliInfo = {}, _cached_display_mode = "full" }
  end

  --- Trimmed from a real `claude -p --output-format stream-json` init line (2.1.231).
  local function init(overrides)
    return vim.json.encode(vim.tbl_extend("force", {
      type = "system",
      subtype = "init",
      session_id = "629ef015-14bd-4b7b-9d88-f2646385c434",
      model = "claude-opus-5",
      claude_code_version = "2.1.231",
      tools = { "Task", "Bash", "Read", "Edit" },
      mcp_servers = { { name = "vibing-nvim", status = "connected" }, { name = "context7", status = "connected" } },
      permissionMode = "default",
    }, overrides or {}))
  end

  it("records the version, the model and the two floor counts", function()
    local context = new_context()

    processor.processLine(init(), context)

    assert.equals("2.1.231", context.cliInfo.version)
    assert.equals("claude-opus-5", context.cliInfo.model)
    assert.equals(4, context.cliInfo.tools)
    assert.equals(2, context.cliInfo.mcp_servers)
  end)

  it("records a compaction, whenever in the stream it lands", function()
    local context = new_context()

    processor.processLine(init(), context)
    processor.processLine(vim.json.encode({ type = "system", subtype = "compact_boundary" }), context)

    assert.is_true(context.cliInfo.compacted)
    -- The init facts are not overwritten by the later event.
    assert.equals("2.1.231", context.cliInfo.version)
  end)

  it("leaves compacted unset on a turn that did not compact", function()
    local context = new_context()

    processor.processLine(init(), context)

    assert.is_nil(context.cliInfo.compacted)
  end)

  it("takes what it can from an init line missing fields", function()
    local context = new_context()

    processor.processLine(
      vim.json.encode({ type = "system", subtype = "init", claude_code_version = "2.1.231" }),
      context
    )

    -- The payload is undocumented, so a field that stops being sent must cost only itself.
    assert.equals("2.1.231", context.cliInfo.version)
    assert.is_nil(context.cliInfo.tools)
    assert.is_nil(context.cliInfo.mcp_servers)
  end)

  it("ignores a system subtype it does not know", function()
    local context = new_context()

    processor.processLine(vim.json.encode({ type = "system", subtype = "hook_callback" }), context)

    assert.same({}, context.cliInfo)
  end)

  it("still cancels the startup timeout on the first system event", function()
    local context = new_context()
    local fired = false
    context.onFirstResponse = function()
      fired = true
    end

    processor.processLine(init(), context)

    assert.is_true(fired)
  end)

  it("does not require the context to carry a cliInfo table", function()
    -- Codex and the other backends share this processor's shape but not this feature.
    local context = { output = {}, errorOutput = {}, _cached_display_mode = "full" }

    assert.has_no.errors(function()
      processor.processLine(init(), context)
    end)
  end)
end)
