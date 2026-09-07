describe("model handler", function()
  local handler
  local original_notify

  before_each(function()
    original_notify = package.loaded["vibing.core.utils.notify"]
    package.loaded["vibing.application.chat.handlers.model"] = nil
    package.loaded["vibing.core.utils.notify"] = {
      error = function() end,
      warn = function() end,
      info = function() end,
    }
    handler = require("vibing.application.chat.handlers.model")
  end)

  after_each(function()
    package.loaded["vibing.application.chat.handlers.model"] = nil
    package.loaded["vibing.core.utils.notify"] = original_notify
  end)

  it("accepts codex model ids and writes them to frontmatter", function()
    local written
    local chat_buffer = {
      update_frontmatter = function(_, key, value)
        written = { key = key, value = value }
        return true
      end,
    }

    assert.is_true(handler({ "gpt-5.6-terra" }, chat_buffer))
    assert.same({ key = "model", value = "gpt-5.6-terra" }, written)
  end)

  it("rejects a model id that belongs to no backend", function()
    local written
    local chat_buffer = {
      update_frontmatter = function(_, key, value)
        written = { key = key, value = value }
        return true
      end,
    }

    assert.is_false(handler({ "sonett" }, chat_buffer))
    assert.is_nil(written)
  end)
end)
