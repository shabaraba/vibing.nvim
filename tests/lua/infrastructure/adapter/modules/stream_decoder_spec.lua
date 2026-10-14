-- The seam every backend's stdout goes through. Its job here is containment: a decoder that cannot
-- handle one line must cost that line and nothing else, because the caller is a stdout callback and
-- a raise out of it drops the rest of the batch -- the `result` that ends the turn included.
local StreamDecoder = require("vibing.infrastructure.adapter.modules.stream_decoder")

describe("stream_decoder", function()
  local notify = require("vibing.core.utils.notify")
  local original_error

  before_each(function()
    original_error = notify.error
  end)

  after_each(function()
    notify.error = original_error
  end)

  --- @return table processor, string[] seen
  local function make_processor()
    local seen = {}
    local processor = StreamDecoder.processor({
      decode = function(msg)
        if msg.type == "bad" then
          error("no idea what this is")
        end
        table.insert(seen, msg.type)
        return {}
      end,
    })
    return processor, seen
  end

  it("keeps decoding after a line the decoder cannot handle", function()
    local reported = {}
    notify.error = function(message)
      table.insert(reported, message)
    end
    local processor, seen = make_processor()
    local context = { output = {}, errorOutput = {} }

    assert.is_false(processor.processLine('{"type":"bad"}', context))
    assert.is_true(processor.processLine('{"type":"result"}', context))
    assert.same({ "result" }, seen)
    assert.equals(1, #reported)
    assert.is_truthy(reported[1]:find("bad", 1, true))
  end)

  it("reports the failure once per stream, not once per line", function()
    -- The shape that fails once fails on every line that carries it, and a notification per line
    -- would bury the one that names the bug.
    local reported = {}
    notify.error = function(message)
      table.insert(reported, message)
    end
    local processor = make_processor()
    local context = { output = {}, errorOutput = {} }

    processor.processLine('{"type":"bad"}', context)
    processor.processLine('{"type":"bad"}', context)
    assert.equals(1, #reported)
  end)
end)
