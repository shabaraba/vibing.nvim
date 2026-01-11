---Shared buffer manager for multi-agent coordination
---Creates and manages shared buffers for inter-Claude communication
local BufferWatcher = require("vibing.core.buffer_watcher")
local MessageParser = require("vibing.application.shared_buffer.message_parser")
local NotificationDispatcher = require("vibing.application.shared_buffer.notification_dispatcher")

local M = {}

---@type number? 共有バッファの番号
local shared_bufnr = nil

---@type boolean 監視が設定済みか
local watcher_setup = false

---共有バッファを作成または取得
---@return number bufnr
function M.get_or_create_shared_buffer()
  if shared_bufnr and vim.api.nvim_buf_is_valid(shared_bufnr) then
    return shared_bufnr
  end

  -- 既存の .vibing-shared バッファを検索
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_get_name(buf)
    if name:match("%.vibing%-shared$") then
      shared_bufnr = buf
      if not watcher_setup then
        M._setup_watcher(shared_bufnr)
      end
      return shared_bufnr
    end
  end

  -- 新規作成
  shared_bufnr = vim.api.nvim_create_buf(false, false)
  vim.bo[shared_bufnr].buftype = ""
  vim.bo[shared_bufnr].filetype = "vibing-shared"
  vim.bo[shared_bufnr].syntax = "markdown"
  vim.bo[shared_bufnr].modifiable = true
  vim.bo[shared_bufnr].swapfile = false

  local save_dir = vim.fn.stdpath("data") .. "/vibing/shared/"
  vim.fn.mkdir(save_dir, "p")
  local filename = "shared-" .. os.date("%Y%m%d") .. ".vibing-shared"
  vim.api.nvim_buf_set_name(shared_bufnr, save_dir .. filename)

  -- 初期コンテンツ
  local lines = {
    "---",
    "vibing.nvim: true",
    "type: shared",
    "created_at: " .. os.date("%Y-%m-%dT%H:%M:%S"),
    "---",
    "",
    "# Shared Buffer",
    "",
    "This buffer is shared among multiple Claude sessions.",
    "Use `@Claude-{id}` to mention a specific session or `@All` for everyone.",
    "",
    "## Usage",
    "",
    "1. Each Claude session has a unique ID (e.g., Claude-abc12)",
    "2. Write messages in the format: `## YYYY-MM-DD HH:MM:SS Claude-{id}`",
    "3. Mention other sessions: `@Claude-{id}` or `@All`",
    "4. Messages with mentions will trigger notifications to relevant sessions",
    "",
  }
  vim.api.nvim_buf_set_lines(shared_bufnr, 0, -1, false, lines)

  M._setup_watcher(shared_bufnr)

  return shared_bufnr
end

---バッファ変更の監視を設定
---@param bufnr number
function M._setup_watcher(bufnr)
  if watcher_setup then
    return
  end

  local ok = BufferWatcher.attach(bufnr, {
    on_change = function(buf, changedtick, firstline, lastline, new_lastline, lines)
      -- 変更された行を解析
      local messages = MessageParser.parse_lines(lines, firstline + 1)

      -- メンションを抽出して通知を配送
      for _, msg in ipairs(messages) do
        -- メンションがある場合のみ通知
        if #msg.mentions > 0 then
          vim.schedule(function()
            NotificationDispatcher.dispatch(msg)
          end)
        end
      end
    end,
  })

  if ok then
    watcher_setup = true
  else
    vim.notify("[vibing] Failed to setup shared buffer watcher", vim.log.levels.ERROR)
  end
end

---共有バッファを開く
---@param position? "current"|"right"|"left"|"float"
function M.open_shared_buffer(position)
  position = position or "right"

  local bufnr = M.get_or_create_shared_buffer()

  if position == "current" then
    vim.api.nvim_set_current_buf(bufnr)
  elseif position == "right" then
    vim.cmd("vsplit")
    vim.api.nvim_set_current_buf(bufnr)
  elseif position == "left" then
    vim.cmd("vsplit")
    vim.cmd("wincmd H")
    vim.api.nvim_set_current_buf(bufnr)
  elseif position == "float" then
    -- フローティングウィンドウで開く
    local width = math.floor(vim.o.columns * 0.8)
    local height = math.floor(vim.o.lines * 0.8)
    local row = math.floor((vim.o.lines - height) / 2)
    local col = math.floor((vim.o.columns - width) / 2)

    local win = vim.api.nvim_open_win(bufnr, true, {
      relative = "editor",
      width = width,
      height = height,
      row = row,
      col = col,
      style = "minimal",
      border = "rounded",
    })

    vim.api.nvim_win_set_buf(win, bufnr)
  end
end

---共有バッファにメッセージを追加
---@param claude_id string
---@param content string
---@param mentions? string[] オプションのメンションリスト
function M.append_message(claude_id, content, mentions)
  local bufnr = M.get_or_create_shared_buffer()

  if not vim.api.nvim_buf_is_valid(bufnr) then
    vim.notify("[vibing] Shared buffer is not valid", vim.log.levels.ERROR)
    return
  end

  -- メンションを追加
  local mention_str = ""
  if mentions and #mentions > 0 then
    mention_str = " " .. table.concat(
      vim.tbl_map(function(m)
        return "@" .. m
      end, mentions),
      " "
    )
  end

  -- ヘッダーを生成
  local header = MessageParser.create_header(claude_id, mention_str)

  -- コンテンツを追加
  local lines = vim.split(header, "\n")
  if content and content ~= "" then
    vim.list_extend(lines, { "", content, "" })
  else
    vim.list_extend(lines, { "" })
  end

  -- バッファの最後に追加
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  vim.api.nvim_buf_set_lines(bufnr, line_count, line_count, false, lines)
end

---共有バッファをクリア（リセット）
function M.clear_shared_buffer()
  if shared_bufnr and vim.api.nvim_buf_is_valid(shared_bufnr) then
    vim.api.nvim_buf_delete(shared_bufnr, { force = true })
    shared_bufnr = nil
    watcher_setup = false
  end
end

---共有バッファが存在するか確認
---@return boolean
function M.has_shared_buffer()
  return shared_bufnr ~= nil and vim.api.nvim_buf_is_valid(shared_bufnr)
end

return M
