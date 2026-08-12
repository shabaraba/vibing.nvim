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

  it("returns the sanitized title from the adapter", function()
    local result_title, result_err
    title_generator.generate_from_conversation(CONVERSATION, function(title, err)
      result_title = title
      result_err = err
    end)

    assert.is_nil(result_err)
    assert.equals("My_Title", result_title)
  end)

  it("uses only the first meaningful line when the model returns tool narration", function()
    -- Defense in depth: even if the lightweight sandbox leaks tools and the model
    -- starts "continuing the session" (tool render markers + narration), the title
    -- must be the first clean line, not the whole multi-line transcript.
    package.loaded["vibing"] = {
      get_config = function()
        return { language = nil, permissions = { mode = "acceptEdits", allow = {}, deny = {} } }
      end,
      get_adapter = function()
        return {
          stream = function(_, _, _, on_chunk, on_done)
            on_chunk("Fix login bug\n⏺ ToolSearch(select:TaskList,TaskCreate)\n📄 Read()\nmore narration")
            on_done({ content = "" })
          end,
        }
      end,
    }

    local result_title
    title_generator.generate_from_conversation(CONVERSATION, function(title)
      result_title = title
    end)

    assert.equals("Fix_login_bug", result_title)
  end)

  it("never resumes/forks a session (avoids 'Prompt is too long')", function()
    -- Title generation must send a fresh excerpt prompt instead of resuming the
    -- full session, so no session_id/fork opts are ever set.
    title_generator.generate_from_conversation(CONVERSATION, function() end)

    assert.is_nil(captured_opts._session_id)
    assert.is_nil(captured_opts._is_fork)
    -- Short conversation: the excerpt still carries the actual content.
    assert.is_not_nil(captured_prompt:find("Hello there", 1, true))
    assert.is_not_nil(captured_prompt:find("General Kenobi", 1, true))
  end)

  it("bounds the prompt for long conversations", function()
    local long = {}
    long[#long + 1] = { role = "user", content = "FIRST_TOPIC_ANCHOR" }
    for i = 1, 40 do
      long[#long + 1] = { role = "assistant", content = "middle message " .. i .. " " .. string.rep("x", 4000) }
    end
    long[#long + 1] = { role = "user", content = "LAST_RECENT_MESSAGE" }

    title_generator.generate_from_conversation(long, function() end)

    -- First user message is kept as a topic anchor and the tail is included...
    assert.is_not_nil(captured_prompt:find("FIRST_TOPIC_ANCHOR", 1, true))
    assert.is_not_nil(captured_prompt:find("LAST_RECENT_MESSAGE", 1, true))
    -- ...but the whole history is not sent verbatim (a far-middle message is dropped).
    assert.is_nil(captured_prompt:find("middle message 1 ", 1, true))
    -- And the total prompt stays bounded.
    assert.is_true(#captured_prompt < 20000)
  end)
end)
