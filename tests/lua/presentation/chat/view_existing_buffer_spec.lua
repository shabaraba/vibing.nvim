-- `view.render` は毎回新しいバッファを作って `nvim_buf_set_name` する。同じ名前のバッファが
-- 既にあるとそこで `E95: Buffer with this name already exists` が出て、`:VibingChat <path>` も
-- `:VibingChatSearch` も落ちる。既にあるバッファを開き直すのがその出口。
local Config = require("vibing.config")
local Frontmatter = require("vibing.infrastructure.storage.frontmatter")

---@param dir string
---@param name string
---@return string path
local function write_chat(dir, name)
  local path = dir .. name .. ".md"
  local content = Frontmatter.serialize({
    ["vibing.nvim"] = true,
    session_id = "session-" .. name,
    created_at = "2025-01-01T00:00:00",
  }, "\n## User\n\nhi\n")
  vim.fn.writefile(vim.split(content, "\n"), path)
  return path
end

---@param path string
---@return Vibing.ChatSession
local function session_for(path)
  return { file_path = path, session_id = "session-from-disk" }
end

describe("view.render with the file already in a buffer", function()
  local view
  local save_dir

  before_each(function()
    save_dir = vim.fn.tempname() .. "_view_chat/"
    vim.fn.mkdir(save_dir, "p")

    local config = vim.deepcopy(Config.defaults)
    config.chat.save_location_type = "custom"
    config.chat.save_dir = save_dir

    package.loaded["vibing"] = {
      get_config = function()
        return config
      end,
    }

    package.loaded["vibing.presentation.chat.view"] = nil
    view = require("vibing.presentation.chat.view")
  end)

  after_each(function()
    view.close()
    view._current_buffer = nil
    view._attached_buffers = {}
    package.loaded["vibing"] = nil
    package.loaded["vibing.presentation.chat.view"] = nil
    vim.fn.delete(save_dir, "rf")
  end)

  it("renders into the buffer that already holds the file", function()
    local path = write_chat(save_dir, "a")
    local bufnr = vim.fn.bufadd(path)
    vim.fn.bufload(bufnr)

    local chat_buf = view.render(session_for(path))

    assert.are.equal(bufnr, chat_buf.buf)
  end)

  it("creates no second buffer for the same file", function()
    local path = write_chat(save_dir, "a")
    -- 読み込みまでやる。`bufadd` だけの unloaded なバッファは `nvim_buf_set_name` が黙って
    -- 消すので E95 にならず、この assertion は守るべきものを守らないまま通る
    vim.fn.bufload(vim.fn.bufadd(path))

    view.render(session_for(path))

    -- バッファ名はシンボリックリンクを解いた形で返るので、数えるほうも realpath で揃える
    -- （揃えないと 0 を数えて「2つ作られていない」が偶然通る）
    local target = vim.loop.fs_realpath(path)
    local holding = 0
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
      local name = vim.api.nvim_buf_get_name(bufnr)
      if name ~= "" and vim.loop.fs_realpath(name) == target then
        holding = holding + 1
      end
    end
    assert.are.equal(1, holding)
  end)

  it("leaves the unsaved edits in that buffer alone", function()
    local path = write_chat(save_dir, "a")
    local bufnr = vim.fn.bufadd(path)
    vim.fn.bufload(bufnr)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "typed but not saved" })

    view.render(session_for(path))

    assert.are.same({ "typed but not saved" }, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
  end)

  it("keeps the ChatBuffer already attached to that buffer", function()
    local path = write_chat(save_dir, "a")
    local bufnr = vim.fn.bufadd(path)
    vim.fn.bufload(bufnr)
    local attached = view.attach_to_buffer(bufnr, path)

    assert.are.equal(attached, view.render(session_for(path)))
    assert.are.equal("session-a", attached.session_id)
  end)

  it("loads an unloaded buffer instead of rendering it as a fresh chat", function()
    local path = write_chat(save_dir, "a")
    local bufnr = vim.fn.bufadd(path)

    local chat_buf = view.render(session_for(path))

    assert.are.equal(bufnr, chat_buf.buf)
    assert.are.same(vim.fn.readfile(path), vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
  end)

  it("still creates a buffer when the file is in none", function()
    local path = write_chat(save_dir, "fresh")

    local chat_buf = view.render(session_for(path))

    assert.is_true(vim.api.nvim_buf_is_valid(chat_buf.buf))
    assert.are.equal("session-from-disk", chat_buf.session_id)
  end)
end)
