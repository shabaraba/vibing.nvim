-- vibing.nvim auto-detection for chat files

---@diagnostic disable-next-line: undefined-global
local vim = vim
local attached_bufs = {}

local function try_attach(buf)
  -- 既にアタッチ済みならスキップ
  if attached_bufs[buf] then
    return
  end

  -- バッファが有効かチェック
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end

  -- ファイル名が.vibingでなければスキップ
  local name = vim.api.nvim_buf_get_name(buf)
  if not name:match("%.vibing$") then
    return
  end

  -- バッファ内容をチェック（大文字小文字を区別しない）
  local lines = vim.api.nvim_buf_get_lines(buf, 0, 5, false)
  local is_vibing_chat = false
  for _, line in ipairs(lines) do
    if line:lower():match("^vibing%.nvim:") then
      is_vibing_chat = true
      break
    end
  end

  if is_vibing_chat then
    attached_bufs[buf] = true
    vim.schedule(function()
      local vibing = require("vibing")
      if not vibing.adapter then
        vibing.setup()
      end
      require("vibing.actions.chat").attach_to_buffer(buf, name)
    end)
  end
end

local group = vim.api.nvim_create_augroup("vibing_chat_detect", { clear = true })

-- 複数のイベントで検出を試みる
vim.api.nvim_create_autocmd({ "BufReadPost", "BufEnter", "BufWinEnter" }, {
  pattern = "*.vibing",
  group = group,
  callback = function(ev)
    try_attach(ev.buf)
  end,
})

-- バッファ削除時のクリーンアップ
vim.api.nvim_create_autocmd("BufDelete", {
  pattern = "*.vibing",
  group = group,
  callback = function(ev)
    attached_bufs[ev.buf] = nil
    local chat = require("vibing.actions.chat")
    if chat.attached_buffers then
      chat.attached_buffers[ev.buf] = nil
    end
  end,
})
