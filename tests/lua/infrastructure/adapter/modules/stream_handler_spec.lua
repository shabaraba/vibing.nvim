local StreamHandler = require("vibing.infrastructure.adapter.modules.stream_handler")

-- Runs the exit handler for a fake process result and returns the response
-- passed to onDone. The handler defers via vim.schedule, so we flush it.
local function run_exit(obj, output, error_output)
  local handles = { h1 = true }
  local captured
  local handler = StreamHandler.create_exit_handler("h1", handles, output or {}, error_output or {}, function(response)
    captured = response
  end)
  handler(obj)
  vim.wait(200, function()
    return captured ~= nil
  end)
  return captured, handles
end

describe("stream_handler.create_exit_handler", function()
  it("does not fail on exit code 0 even when stderr has warnings", function()
    -- Regression: a non-fatal stderr warning (e.g. codex "failed to load models
    -- cache") must not discard a successful stdout result.
    local res = run_exit({ code = 0 }, { "generated title" }, { "WARN: failed to load models cache" })

    assert.is_nil(res.error)
    assert.equals("generated title", res.content)
  end)

  it("reports an error when the process exits non-zero", function()
    local res = run_exit({ code = 1 }, {}, { "boom" })

    assert.equals("boom", res.error)
  end)

  it("uses a generic error message on non-zero exit with empty stderr", function()
    local res = run_exit({ code = 2 }, {}, {})

    assert.is_not_nil(res.error)
    assert.is_not_nil(res.error:match("code 2"))
  end)

  it("succeeds on exit code 0 with no stderr", function()
    local res = run_exit({ code = 0 }, { "ok" }, {})

    assert.is_nil(res.error)
    assert.equals("ok", res.content)
  end)

  it("clears the handle from the handles map", function()
    local _, handles = run_exit({ code = 0 }, { "ok" }, {})

    assert.is_nil(handles.h1)
  end)
end)
