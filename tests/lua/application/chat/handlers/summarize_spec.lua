local summarize = require("vibing.application.chat.handlers.summarize")

---@param session_id string?
---@return table chat_buffer
local function make_chat_buffer(session_id)
  local buf = vim.api.nvim_create_buf(false, true)
  return {
    buf = buf,
    extract_conversation = function()
      return {
        { role = "user", content = "Hello" },
        { role = "assistant", content = "Hi there" },
      }
    end,
    get_session_id = function()
      return session_id
    end,
  }
end

describe("summarize handler", function()
  local captured_prompt, captured_opts

  before_each(function()
    captured_prompt = nil
    captured_opts = nil

    package.loaded["vibing"] = {
      get_config = function()
        return {
          permissions = { mode = "acceptEdits", allow = { "Read" }, deny = { "Bash" } },
        }
      end,
      get_adapter = function()
        return {
          stream = function(_, prompt, opts, _on_chunk, on_done)
            captured_prompt = prompt
            captured_opts = opts
            -- Return an error to skip the float-window rendering path, which is
            -- unrelated to the session_id branching logic under test here.
            on_done({ error = "stubbed" })
          end,
        }
      end,
    }
  end)

  after_each(function()
    package.loaded["vibing"] = nil
  end)

  it("sends only the short instruction and sets fork opts when a session_id exists", function()
    local chat_buffer = make_chat_buffer("session-abc")
    local ok = summarize({}, chat_buffer)

    assert.is_true(ok)
    assert.equals("session-abc", captured_opts._session_id)
    assert.is_true(captured_opts._is_fork)
    assert.is_nil(captured_prompt:find("Hello", 1, true))
    assert.is_not_nil(captured_prompt:find("summarize", 1, true))
  end)

  it("passes configured permissions through opts", function()
    local chat_buffer = make_chat_buffer("session-abc")
    summarize({}, chat_buffer)

    assert.equals("acceptEdits", captured_opts.permission_mode)
    assert.same({ "Read" }, captured_opts.permissions_allow)
    assert.same({ "Bash" }, captured_opts.permissions_deny)
  end)

  it("falls back to sending the full conversation text when there is no session_id", function()
    local chat_buffer = make_chat_buffer(nil)
    local ok = summarize({}, chat_buffer)

    assert.is_true(ok)
    assert.is_nil(captured_opts._session_id)
    assert.is_nil(captured_opts._is_fork)
    assert.is_not_nil(captured_prompt:find("Hello", 1, true))
    assert.is_not_nil(captured_prompt:find("Hi there", 1, true))
  end)

  it("falls back to full conversation text when session_id is an empty string", function()
    local chat_buffer = make_chat_buffer("")
    summarize({}, chat_buffer)

    assert.is_nil(captured_opts._session_id)
    assert.is_not_nil(captured_prompt:find("Hello", 1, true))
  end)
end)
