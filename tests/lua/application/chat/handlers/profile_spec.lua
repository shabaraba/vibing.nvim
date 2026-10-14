describe("profile handler", function()
  local handler
  local original_notify

  before_each(function()
    original_notify = package.loaded["vibing.core.utils.notify"]
    package.loaded["vibing.application.chat.handlers.profile"] = nil
    package.loaded["vibing.core.utils.notify"] = {
      error = function() end,
      warn = function() end,
      info = function() end,
    }
    handler = require("vibing.application.chat.handlers.profile")
  end)

  after_each(function()
    package.loaded["vibing.application.chat.handlers.profile"] = nil
    package.loaded["vibing.core.utils.notify"] = original_notify
  end)

  local function recording_buffer()
    local buffer = { written = nil }
    function buffer:update_frontmatter(key, value)
      self.written = { key = key, value = value }
      return true
    end
    return buffer
  end

  it("takes a narrowed chat back to the ordinary profile", function()
    local chat_buffer = recording_buffer()

    assert.is_true(handler({ "default" }, chat_buffer))
    assert.same({ key = "profile", value = "default" }, chat_buffer.written)
  end)

  it("can put an ordinary chat on a narrowed built-in", function()
    local chat_buffer = recording_buffer()

    assert.is_true(handler({ "focused" }, chat_buffer))
    assert.same({ key = "profile", value = "focused" }, chat_buffer.written)
  end)

  it("no longer knows the removed worker profile", function()
    local chat_buffer = recording_buffer()

    assert.is_false(handler({ "worker" }, chat_buffer))
    assert.is_nil(chat_buffer.written)
  end)

  it("rejects an unknown profile without touching the frontmatter", function()
    local chat_buffer = recording_buffer()

    assert.is_false(handler({ "lean" }, chat_buffer))
    assert.is_nil(chat_buffer.written)
  end)

  it("rejects a missing argument without touching the frontmatter", function()
    local chat_buffer = recording_buffer()

    assert.is_false(handler({}, chat_buffer))
    assert.is_nil(chat_buffer.written)
  end)
end)
