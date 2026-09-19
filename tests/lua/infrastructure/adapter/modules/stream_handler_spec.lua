local StreamHandler = require("vibing.infrastructure.adapter.modules.stream_handler")

-- The two ids are deliberately different values, so a site that reaches the process table with the
-- turn id (or vice versa) misses instead of working by coincidence (#774).
local IDS = { turn_id = "t1", process_id = "p1" }

-- Runs the exit handler for a fake process result and returns the response
-- passed to onDone. The handler defers via vim.schedule, so we flush it.
local function run_exit(obj, output, error_output)
  local processes = { p1 = true, t1 = true }
  local captured
  local handler = StreamHandler.create_exit_handler(IDS, processes, output or {}, error_output or {}, function(response)
    captured = response
  end)
  handler(obj)
  vim.wait(200, function()
    return captured ~= nil
  end)
  return captured, processes
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

  it("clears the process from the process map by process id, not turn id", function()
    local _, processes = run_exit({ code = 0 }, { "ok" }, {})

    assert.is_nil(processes.p1)
    assert.is_true(processes.t1, "the turn id was used to address the process table")
  end)

  it("names both the turn and the process on every response it produces", function()
    -- `_handle_id` is what `_handle_response`'s staleness check compares; `_process_id` is what the
    -- session read-back reads. A response carrying only one is unattributable on the other axis.
    for _, obj in ipairs({ { code = 0 }, { code = 1 } }) do
      local res = run_exit(obj, { "ok" }, {})
      assert.equals("t1", res._handle_id)
      assert.equals("p1", res._process_id)
    end
  end)
end)
