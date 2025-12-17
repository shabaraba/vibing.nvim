-- Tests for vibing.chat.handlers modules

describe("vibing.chat.handlers.clear", function()
  local clear_handler
  local mock_chat_buffer
  local mock_context

  before_each(function()
    -- Clear loaded modules
    package.loaded["vibing.context"] = nil
    package.loaded["vibing.chat.handlers.clear"] = nil

    -- Mock context module
    mock_context = {
      clear = function() end,
    }
    package.loaded["vibing.context"] = mock_context

    clear_handler = require("vibing.chat.handlers.clear")

    -- Mock chat buffer
    mock_chat_buffer = {
      _update_context_line = function(self) end,
    }
  end)

  it("should call context.clear", function()
    local clear_called = false
    mock_context.clear = function()
      clear_called = true
    end

    clear_handler({}, mock_chat_buffer)

    assert.is_true(clear_called)
  end)

  it("should update chat buffer context line", function()
    local update_called = false
    mock_chat_buffer._update_context_line = function(self)
      update_called = true
    end

    clear_handler({}, mock_chat_buffer)

    assert.is_true(update_called)
  end)

  it("should return true on success", function()
    local result = clear_handler({}, mock_chat_buffer)
    assert.is_true(result)
  end)

  it("should handle nil chat_buffer gracefully", function()
    local result = clear_handler({}, nil)
    assert.is_true(result)
  end)
end)

describe("vibing.chat.handlers.context", function()
  local context_handler
  local mock_chat_buffer
  local mock_context

  before_each(function()
    -- Clear loaded modules
    package.loaded["vibing.context"] = nil
    package.loaded["vibing.chat.handlers.context"] = nil

    -- Mock context module
    mock_context = {
      add = function(path) end,
    }
    package.loaded["vibing.context"] = mock_context

    context_handler = require("vibing.chat.handlers.context")

    -- Mock chat buffer
    mock_chat_buffer = {
      _update_context_line = function(self) end,
    }
  end)

  it("should return false when no args provided", function()
    local result = context_handler({}, mock_chat_buffer)
    assert.is_false(result)
  end)

  it("should return false when file is not readable", function()
    local original_filereadable = vim.fn.filereadable
    vim.fn.filereadable = function()
      return 0
    end

    local result = context_handler({ "/nonexistent.txt" }, mock_chat_buffer)
    assert.is_false(result)

    -- Restore
    vim.fn.filereadable = original_filereadable
  end)

  it("should add readable file to context", function()
    local original_filereadable = vim.fn.filereadable
    local original_expand = vim.fn.expand
    vim.fn.filereadable = function()
      return 1
    end
    vim.fn.expand = function(path)
      return path
    end

    local added_path = nil
    mock_context.add = function(path)
      added_path = path
    end

    local result = context_handler({ "/tmp/test.lua" }, mock_chat_buffer)

    assert.is_true(result)
    assert.equals("/tmp/test.lua", added_path)

    -- Restore
    vim.fn.filereadable = original_filereadable
    vim.fn.expand = original_expand
  end)

  it("should update chat buffer context line", function()
    local original_filereadable = vim.fn.filereadable
    local original_expand = vim.fn.expand
    vim.fn.filereadable = function()
      return 1
    end
    vim.fn.expand = function(path)
      return path
    end

    local update_called = false
    mock_chat_buffer._update_context_line = function(self)
      update_called = true
    end

    context_handler({ "/tmp/test.lua" }, mock_chat_buffer)

    assert.is_true(update_called)

    -- Restore
    vim.fn.filereadable = original_filereadable
    vim.fn.expand = original_expand
  end)
end)

describe("vibing.chat.handlers.mode", function()
  local mode_handler
  local mock_chat_buffer

  before_each(function()
    package.loaded["vibing.chat.handlers.mode"] = nil
    mode_handler = require("vibing.chat.handlers.mode")

    mock_chat_buffer = {
      update_frontmatter = function(self, key, value)
        return true
      end,
    }
  end)

  it("should return false when no args provided", function()
    local result = mode_handler({}, mock_chat_buffer)
    assert.is_false(result)
  end)

  it("should return false when mode is invalid", function()
    local result = mode_handler({ "invalid" }, mock_chat_buffer)
    assert.is_false(result)
  end)

  it("should return false when chat_buffer is nil", function()
    local result = mode_handler({ "auto" }, nil)
    assert.is_false(result)
  end)

  it("should accept valid mode 'auto'", function()
    local updated_key = nil
    local updated_value = nil
    mock_chat_buffer.update_frontmatter = function(self, key, value)
      updated_key = key
      updated_value = value
      return true
    end

    local result = mode_handler({ "auto" }, mock_chat_buffer)

    assert.is_true(result)
    assert.equals("mode", updated_key)
    assert.equals("auto", updated_value)
  end)

  it("should accept valid mode 'plan'", function()
    local updated_value = nil
    mock_chat_buffer.update_frontmatter = function(self, key, value)
      updated_value = value
      return true
    end

    local result = mode_handler({ "plan" }, mock_chat_buffer)

    assert.is_true(result)
    assert.equals("plan", updated_value)
  end)

  it("should accept valid mode 'code'", function()
    local updated_value = nil
    mock_chat_buffer.update_frontmatter = function(self, key, value)
      updated_value = value
      return true
    end

    local result = mode_handler({ "code" }, mock_chat_buffer)

    assert.is_true(result)
    assert.equals("code", updated_value)
  end)

  it("should return false when frontmatter update fails", function()
    mock_chat_buffer.update_frontmatter = function(self, key, value)
      return false
    end

    local result = mode_handler({ "auto" }, mock_chat_buffer)
    assert.is_false(result)
  end)
end)

describe("vibing.chat.handlers.model", function()
  local model_handler
  local mock_chat_buffer

  before_each(function()
    package.loaded["vibing.chat.handlers.model"] = nil
    model_handler = require("vibing.chat.handlers.model")

    mock_chat_buffer = {
      update_frontmatter = function(self, key, value)
        return true
      end,
    }
  end)

  it("should return false when no args provided", function()
    local result = model_handler({}, mock_chat_buffer)
    assert.is_false(result)
  end)

  it("should return false when model is invalid", function()
    local result = model_handler({ "invalid" }, mock_chat_buffer)
    assert.is_false(result)
  end)

  it("should return false when chat_buffer is nil", function()
    local result = model_handler({ "opus" }, nil)
    assert.is_false(result)
  end)

  it("should accept valid model 'opus'", function()
    local updated_key = nil
    local updated_value = nil
    mock_chat_buffer.update_frontmatter = function(self, key, value)
      updated_key = key
      updated_value = value
      return true
    end

    local result = model_handler({ "opus" }, mock_chat_buffer)

    assert.is_true(result)
    assert.equals("model", updated_key)
    assert.equals("opus", updated_value)
  end)

  it("should accept valid model 'sonnet'", function()
    local updated_value = nil
    mock_chat_buffer.update_frontmatter = function(self, key, value)
      updated_value = value
      return true
    end

    local result = model_handler({ "sonnet" }, mock_chat_buffer)

    assert.is_true(result)
    assert.equals("sonnet", updated_value)
  end)

  it("should accept valid model 'haiku'", function()
    local updated_value = nil
    mock_chat_buffer.update_frontmatter = function(self, key, value)
      updated_value = value
      return true
    end

    local result = model_handler({ "haiku" }, mock_chat_buffer)

    assert.is_true(result)
    assert.equals("haiku", updated_value)
  end)

  it("should return false when frontmatter update fails", function()
    mock_chat_buffer.update_frontmatter = function(self, key, value)
      return false
    end

    local result = model_handler({ "opus" }, mock_chat_buffer)
    assert.is_false(result)
  end)
end)

describe("vibing.chat.handlers.save", function()
  local save_handler
  local mock_chat_buffer

  before_each(function()
    package.loaded["vibing.chat.handlers.save"] = nil
    save_handler = require("vibing.chat.handlers.save")

    mock_chat_buffer = {
      buf = 1,
    }
  end)

  it("should return false when chat_buffer is nil", function()
    local result = save_handler({}, nil)
    assert.is_false(result)
  end)

  it("should return false when chat_buffer.buf is nil", function()
    mock_chat_buffer.buf = nil
    local result = save_handler({}, mock_chat_buffer)
    assert.is_false(result)
  end)

  it("should return false when buffer is invalid", function()
    local original_is_valid = vim.api.nvim_buf_is_valid
    vim.api.nvim_buf_is_valid = function()
      return false
    end

    local result = save_handler({}, mock_chat_buffer)
    assert.is_false(result)

    -- Restore
    vim.api.nvim_buf_is_valid = original_is_valid
  end)

  it("should execute write command when buffer is valid", function()
    local original_is_valid = vim.api.nvim_buf_is_valid
    local original_cmd = vim.cmd
    vim.api.nvim_buf_is_valid = function()
      return true
    end

    local cmd_called = false
    local cmd_arg = nil
    vim.cmd = function(arg)
      cmd_called = true
      cmd_arg = arg
    end

    local result = save_handler({}, mock_chat_buffer)

    assert.is_true(result)
    assert.is_true(cmd_called)
    assert.is_not_nil(cmd_arg:match("buffer 1"))
    assert.is_not_nil(cmd_arg:match("write"))

    -- Restore
    vim.api.nvim_buf_is_valid = original_is_valid
    vim.cmd = original_cmd
  end)

  it("should return false when write command fails", function()
    local original_is_valid = vim.api.nvim_buf_is_valid
    local original_cmd = vim.cmd
    vim.api.nvim_buf_is_valid = function()
      return true
    end
    vim.cmd = function()
      error("write failed")
    end

    local result = save_handler({}, mock_chat_buffer)
    assert.is_false(result)

    -- Restore
    vim.api.nvim_buf_is_valid = original_is_valid
    vim.cmd = original_cmd
  end)
end)

describe("vibing.chat.handlers.summarize", function()
  local summarize_handler
  local mock_chat_buffer
  local mock_adapter
  local mock_vibing

  before_each(function()
    package.loaded["vibing"] = nil
    package.loaded["vibing.chat.handlers.summarize"] = nil

    -- Mock adapter
    mock_adapter = {
      stream = function(self, prompt, opts, on_chunk, on_complete) end,
    }

    -- Mock vibing module
    mock_vibing = {
      get_adapter = function()
        return mock_adapter
      end,
    }
    package.loaded["vibing"] = mock_vibing

    summarize_handler = require("vibing.chat.handlers.summarize")

    mock_chat_buffer = {
      buf = 1,
      extract_conversation = function(self)
        return {
          { role = "user", content = "Hello" },
          { role = "assistant", content = "Hi" },
        }
      end,
    }
  end)

  it("should return false when chat_buffer is nil", function()
    local result = summarize_handler({}, nil)
    assert.is_false(result)
  end)

  it("should return false when buffer is invalid", function()
    local original_is_valid = vim.api.nvim_buf_is_valid
    vim.api.nvim_buf_is_valid = function()
      return false
    end

    local result = summarize_handler({}, mock_chat_buffer)
    assert.is_false(result)

    -- Restore
    vim.api.nvim_buf_is_valid = original_is_valid
  end)

  it("should return false when no conversation exists", function()
    local original_is_valid = vim.api.nvim_buf_is_valid
    vim.api.nvim_buf_is_valid = function()
      return true
    end
    mock_chat_buffer.extract_conversation = function(self)
      return {}
    end

    local result = summarize_handler({}, mock_chat_buffer)
    assert.is_false(result)

    -- Restore
    vim.api.nvim_buf_is_valid = original_is_valid
  end)

  it("should return false when no adapter is configured", function()
    local original_is_valid = vim.api.nvim_buf_is_valid
    vim.api.nvim_buf_is_valid = function()
      return true
    end
    mock_vibing.get_adapter = function()
      return nil
    end

    local result = summarize_handler({}, mock_chat_buffer)
    assert.is_false(result)

    -- Restore
    vim.api.nvim_buf_is_valid = original_is_valid
  end)

  it("should call adapter stream with conversation text", function()
    local original_is_valid = vim.api.nvim_buf_is_valid
    vim.api.nvim_buf_is_valid = function()
      return true
    end

    local stream_prompt = nil
    mock_adapter.stream = function(self, prompt, opts, on_chunk, on_complete)
      stream_prompt = prompt
    end

    local result = summarize_handler({}, mock_chat_buffer)

    assert.is_true(result)
    assert.is_not_nil(stream_prompt)
    assert.is_not_nil(stream_prompt:match("%[user%]: Hello"))
    assert.is_not_nil(stream_prompt:match("%[assistant%]: Hi"))
    assert.is_not_nil(stream_prompt:match("summarize"))

    -- Restore
    vim.api.nvim_buf_is_valid = original_is_valid
  end)

  it("should return true when stream is initiated successfully", function()
    local original_is_valid = vim.api.nvim_buf_is_valid
    vim.api.nvim_buf_is_valid = function()
      return true
    end

    local result = summarize_handler({}, mock_chat_buffer)
    assert.is_true(result)

    -- Restore
    vim.api.nvim_buf_is_valid = original_is_valid
  end)
end)
