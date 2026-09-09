describe("vibing.infrastructure.storage.chat_detect", function()
  local original_create_autocmd
  local original_create_augroup
  local original_schedule
  local callbacks
  local buf

  before_each(function()
    package.loaded["vibing.infrastructure.storage.chat_detect"] = nil
    original_create_autocmd = vim.api.nvim_create_autocmd
    original_create_augroup = vim.api.nvim_create_augroup
    original_schedule = vim.schedule
    callbacks = {}

    vim.api.nvim_create_augroup = function()
      return 1
    end
    vim.api.nvim_create_autocmd = function(events, opts)
      local event_list = type(events) == "table" and events or { events }
      for _, event in ipairs(event_list) do
        callbacks[event] = opts.callback
      end
      return 1
    end
    vim.schedule = function(callback)
      callback()
    end

    buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(buf, vim.fn.tempname() .. ".md")
  end)

  after_each(function()
    vim.api.nvim_create_autocmd = original_create_autocmd
    vim.api.nvim_create_augroup = original_create_augroup
    vim.schedule = original_schedule
    package.loaded["vibing.infrastructure.storage.chat_detect"] = nil
    package.loaded["vibing.infrastructure.storage.frontmatter"] = nil
    package.loaded["vibing.presentation.chat.view"] = nil
    if vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
  end)

  it("reattaches chat settings when :edit unloads and reloads the same buffer", function()
    local attach_count = 0
    package.loaded["vibing.infrastructure.storage.frontmatter"] = {
      is_vibing_chat_buffer = function()
        return true
      end,
    }
    package.loaded["vibing.presentation.chat.view"] = {
      attach_to_buffer = function()
        attach_count = attach_count + 1
      end,
      _attached_buffers = {},
    }

    local chat_detect = require("vibing.infrastructure.storage.chat_detect")
    chat_detect.setup()

    callbacks.BufReadPost({ buf = buf })
    assert.equals(1, attach_count)
    assert.is_true(chat_detect.is_attached(buf))

    -- Repeated enter events remain cheap while the attachment is alive.
    callbacks.BufEnter({ buf = buf })
    assert.equals(1, attach_count)

    callbacks.BufUnload({ buf = buf })
    assert.is_false(chat_detect.is_attached(buf))
    callbacks.BufReadPost({ buf = buf })
    assert.equals(2, attach_count)
    assert.is_true(chat_detect.is_attached(buf))
  end)
end)
