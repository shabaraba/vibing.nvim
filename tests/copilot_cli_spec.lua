describe("copilot_cli adapter", function()
  local CopilotCLI

  before_each(function()
    package.loaded["vibing.infrastructure.adapter.copilot_cli"] = nil
    CopilotCLI = require("vibing.infrastructure.adapter.copilot_cli")
  end)

  it("creates an instance named copilot_cli", function()
    local adapter = CopilotCLI:new({})
    assert.are.equal("copilot_cli", adapter.name)
  end)

  it("declares its supported features", function()
    local adapter = CopilotCLI:new({})
    assert.is_true(adapter:supports("streaming"))
    assert.is_true(adapter:supports("tools"))
    assert.is_true(adapter:supports("model_selection"))
    assert.is_true(adapter:supports("context"))
    assert.is_true(adapter:supports("session"))
    assert.is_false(adapter:supports("nonexistent_feature"))
  end)

  it("round-trips a session id per handle", function()
    local adapter = CopilotCLI:new({})
    adapter:set_session_id("sess-1", "handle-a")
    adapter:set_session_id("sess-2", "handle-b")
    assert.are.equal("sess-1", adapter:get_session_id("handle-a"))
    assert.are.equal("sess-2", adapter:get_session_id("handle-b"))
  end)

  it("clears a session id on cleanup_session", function()
    local adapter = CopilotCLI:new({})
    adapter:set_session_id("sess-1", "handle-a")
    adapter:cleanup_session("handle-a")
    assert.is_nil(adapter:get_session_id("handle-a"))
  end)

  it("drops sessions with no live handle on cleanup_stale_sessions", function()
    local adapter = CopilotCLI:new({})
    adapter:set_session_id("sess-1", "handle-a")
    adapter:cleanup_stale_sessions()
    assert.is_nil(adapter:get_session_id("handle-a"))
  end)

  it("reports a missing copilot binary through on_done instead of raising", function()
    local original_exepath = vim.fn.exepath
    vim.fn.exepath = function()
      return ""
    end

    local adapter = CopilotCLI:new({})
    local response, raised = nil, nil
    local ok = pcall(function()
      adapter:stream("hi", {}, function() end, function(r)
        response = r
      end)
    end)
    raised = not ok

    vim.fn.exepath = original_exepath
    vim.wait(500, function()
      return response ~= nil
    end, 10)

    assert.is_false(raised)
    assert.is_not_nil(response)
    assert.are.equal("Copilot CLI not found in PATH. Please install GitHub Copilot CLI.", response.error)
  end)

  it("does not error when cancelling an unknown handle", function()
    local adapter = CopilotCLI:new({})
    assert.has_no.errors(function()
      adapter:cancel("no-such-handle")
    end)
  end)
end)
