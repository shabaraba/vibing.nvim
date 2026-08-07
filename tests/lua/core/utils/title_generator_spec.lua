local title_generator = require("vibing.core.utils.title_generator")

local CONVERSATION = {
  { role = "user", content = "Hello there" },
  { role = "assistant", content = "General Kenobi" },
}

describe("title_generator.generate_from_conversation", function()
  local captured_prompt, captured_opts

  before_each(function()
    captured_prompt = nil
    captured_opts = nil

    package.loaded["vibing"] = {
      get_config = function()
        return {
          language = nil,
          permissions = { mode = "acceptEdits", allow = {}, deny = {} },
        }
      end,
      get_adapter = function()
        return {
          stream = function(_, prompt, opts, on_chunk, on_done)
            captured_prompt = prompt
            captured_opts = opts
            on_chunk("My Title")
            on_done({ content = "" })
          end,
        }
      end,
    }
  end)

  after_each(function()
    package.loaded["vibing"] = nil
  end)

  it("sends only the short instruction and sets fork opts when session_id is provided", function()
    local result_title, result_err
    title_generator.generate_from_conversation(CONVERSATION, function(title, err)
      result_title = title
      result_err = err
    end, "session-abc")

    assert.is_nil(result_err)
    assert.equals("My_Title", result_title)
    assert.equals("session-abc", captured_opts._session_id)
    assert.is_true(captured_opts._is_fork)
    assert.is_nil(captured_prompt:find("Hello there", 1, true))
  end)

  it("falls back to sending the full conversation text when session_id is omitted", function()
    title_generator.generate_from_conversation(CONVERSATION, function() end)

    assert.is_nil(captured_opts._session_id)
    assert.is_nil(captured_opts._is_fork)
    assert.is_not_nil(captured_prompt:find("Hello there", 1, true))
    assert.is_not_nil(captured_prompt:find("General Kenobi", 1, true))
  end)

  it("falls back to full conversation text when session_id is an empty string", function()
    title_generator.generate_from_conversation(CONVERSATION, function() end, "")

    assert.is_nil(captured_opts._session_id)
    assert.is_not_nil(captured_prompt:find("Hello there", 1, true))
  end)
end)
