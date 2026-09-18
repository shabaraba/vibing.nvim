--- The gate's own permission question, answered over the control channel (#778, decision 1).
---
--- The envelope here is a recorded measurement, not a design choice: three candidate shapes were
--- tried against claude 2.1.236 and the first was the one the CLI acted on
--- (`tests/perf/permission_prompt_tool.sh`, logs under `.vibing/probe/permission-prompt-tool/`).
--- A shape the CLI does not recognise is ignored with `Ignoring can_use_tool control_response` and
--- the turn stalls, so the nesting is asserted literally.

local Control = require("vibing.infrastructure.adapter.modules.duplex_control")

describe("duplex control channel", function()
  local function request(overrides)
    return vim.tbl_deep_extend("force", {
      type = "control_request",
      request_id = "req-1",
      request = {
        subtype = "can_use_tool",
        tool_name = "Write",
        input = { file_path = "/tmp/x", content = "ok" },
      },
    }, overrides or {})
  end

  describe("recognising the question", function()
    it("accepts the shape the CLI was measured to send", function()
      assert.is_true(Control.is_permission_request(request()))
    end)

    it("rejects every other control request, and every ordinary line", function()
      -- `interrupt` travels the same envelope and must not be answered as a permission question --
      -- `duplex_process.interrupt` sends one on every cancel, so this is a live collision rather
      -- than a hypothetical one.
      assert.is_false(Control.is_permission_request(request({ request = { subtype = "interrupt" } })))
      assert.is_false(Control.is_permission_request({ type = "assistant", message = {} }))
      assert.is_false(Control.is_permission_request({ type = "control_response", response = {} }))
      assert.is_false(Control.is_permission_request(nil))
      assert.is_false(Control.is_permission_request("not a table"))
    end)

    it("rejects a request with no id, which could not be answered anyway", function()
      local no_id = request()
      no_id.request_id = nil
      assert.is_false(Control.is_permission_request(no_id))
    end)
  end)

  describe("the answer", function()
    it("is the envelope the CLI was measured to act on", function()
      local answer = Control.allow_response("req-7", { file_path = "/tmp/x" })
      assert.equals("control_response", answer.type)
      assert.equals("success", answer.response.subtype)
      assert.equals("req-7", answer.response.request_id)
      assert.equals("allow", answer.response.response.behavior)
      assert.same({ file_path = "/tmp/x" }, answer.response.response.updatedInput)
    end)

    it("survives a round trip through the JSON encoder", function()
      -- The reply reaches the CLI as one encoded line, so a shape that only holds as a Lua table
      -- is no use. An empty input must encode as `{}` rather than `[]`, which is what
      -- `vim.empty_dict` is for -- a bare `{}` would arrive as a JSON array and be rejected.
      local encoded = vim.json.encode(Control.allow_response("req-8", nil))
      local decoded = vim.json.decode(encoded)
      assert.equals("allow", decoded.response.response.behavior)
      assert.is_false(encoded:find("%[%]") ~= nil, "empty input encoded as a JSON array: " .. encoded)
    end)
  end)

  describe("answering", function()
    it("replies once and reports the line consumed", function()
      local sent = {}
      local consumed = Control.try_answer(request(), function(payload)
        table.insert(sent, payload)
        return true
      end)
      assert.is_true(consumed)
      assert.equals(1, #sent)
      assert.equals("req-1", sent[1].response.request_id)
    end)

    it("leaves anything else for the decoder", function()
      -- Consuming a line the decoder needed would lose a turn's output; the return value is what
      -- the router branches on, so it is the contract rather than an implementation detail.
      local called = false
      local consumed = Control.try_answer({ type = "assistant" }, function()
        called = true
        return true
      end)
      assert.is_false(consumed)
      assert.is_false(called)
    end)

    it("still consumes the line when the write fails", function()
      -- The write can fail on a process that is dying, and re-handing the line to the decoder would
      -- not help: it is not a turn event. What matters is that the failure is reported rather than
      -- read as a model that went quiet.
      local notified = {}
      local original = vim.notify
      vim.notify = function(msg, level)
        table.insert(notified, { msg = msg, level = level })
      end
      local ok, consumed = pcall(Control.try_answer, request(), function()
        return false
      end)
      vim.notify = original

      assert.is_true(ok)
      assert.is_true(consumed)
      assert.equals(1, #notified)
      assert.is_true(notified[1].msg:find("Write", 1, true) ~= nil)
      assert.equals(vim.log.levels.ERROR, notified[1].level)
    end)
  end)
end)
