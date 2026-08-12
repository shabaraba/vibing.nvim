describe("set_file_title handler - streaming guard", function()
  local handler

  before_each(function()
    package.loaded["vibing.application.chat.handlers.set_file_title"] = nil
    handler = require("vibing.application.chat.handlers.set_file_title")
  end)

  after_each(function()
    package.loaded["vibing.application.chat.handlers.set_file_title"] = nil
  end)

  it("returns false and skips title generation while the main response is streaming", function()
    local generate_called = false
    local original_generate = require("vibing.core.utils.title_generator").generate_from_conversation
    require("vibing.core.utils.title_generator").generate_from_conversation = function()
      generate_called = true
    end

    local buf = vim.api.nvim_create_buf(false, true)
    local chat_buffer = {
      buf = buf,
      is_sending = function()
        return true
      end,
      extract_conversation = function()
        return { { role = "user", content = "hi" } }
      end,
    }

    local ok = handler({}, chat_buffer)

    assert.is_false(ok)
    assert.is_false(generate_called)

    require("vibing.core.utils.title_generator").generate_from_conversation = original_generate
  end)

  it("proceeds to title generation when not sending", function()
    local generate_called = false
    local original_generate = require("vibing.core.utils.title_generator").generate_from_conversation
    require("vibing.core.utils.title_generator").generate_from_conversation = function()
      generate_called = true
    end

    local buf = vim.api.nvim_create_buf(false, true)
    local chat_buffer = {
      buf = buf,
      is_sending = function()
        return false
      end,
      extract_conversation = function()
        return { { role = "user", content = "hi" } }
      end,
      get_session_id = function()
        return nil
      end,
    }

    handler({}, chat_buffer)

    assert.is_true(generate_called)

    require("vibing.core.utils.title_generator").generate_from_conversation = original_generate
  end)

  it("resolves the per-chat agent adapter (codex chat -> codex adapter)", function()
    require("vibing").setup({})

    local passed_adapter
    local original_generate = require("vibing.core.utils.title_generator").generate_from_conversation
    require("vibing.core.utils.title_generator").generate_from_conversation = function(_, _, adapter)
      passed_adapter = adapter
    end

    local buf = vim.api.nvim_create_buf(false, true)
    local chat_buffer = {
      buf = buf,
      is_sending = function()
        return false
      end,
      extract_conversation = function()
        return { { role = "user", content = "hi" } }
      end,
      get_session_id = function()
        return "codex-session-123"
      end,
      parse_frontmatter = function()
        return { agent = "codex" }
      end,
    }

    handler({}, chat_buffer)

    -- The lightweight title call must run on the per-chat agent's adapter (codex),
    -- not the global default (claude). Title generation does not resume, so no
    -- session_id is threaded through.
    assert.is_not_nil(passed_adapter)
    assert.equals("codex_cli", passed_adapter.name)

    require("vibing.core.utils.title_generator").generate_from_conversation = original_generate
  end)

  it("falls back to a message-based name when title generation fails", function()
    require("vibing").setup({ chat = { save_location_type = "custom", save_dir = "/tmp/vibing_title_fb" } })
    vim.fn.mkdir("/tmp/vibing_title_fb", "p")

    -- Simulate the real failure (e.g. "Prompt is too long"): the callback is
    -- invoked with an error. The handler must still name the file, not bail out.
    local original_generate = require("vibing.core.utils.title_generator").generate_from_conversation
    require("vibing.core.utils.title_generator").generate_from_conversation = function(_, cb)
      cb(nil, "Prompt is too long")
    end

    local buf = vim.api.nvim_create_buf(false, true)
    local chat_buffer = {
      buf = buf,
      file_path = nil,
      is_sending = function()
        return false
      end,
      extract_conversation = function()
        return { { role = "user", content = "Fix the login bug" } }
      end,
      get_session_id = function()
        return nil
      end,
      parse_frontmatter = function()
        return {}
      end,
    }

    local ok = handler({}, chat_buffer)
    assert.is_true(ok)

    -- The buffer is renamed from the first user message, not left unnamed.
    local name = vim.api.nvim_buf_get_name(buf)
    assert.is_not_nil(name:match("chat%-%d+%-Fix_the_login_bug%.md$"))

    require("vibing.core.utils.title_generator").generate_from_conversation = original_generate
    if vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
  end)
end)
