local commands = require("vibing.chat.commands")

---@class Vibing.Completion
---スラッシュコマンド補完機能
---Neovimのomnifuncを実装し、/を入力すると自動的にコマンド候補を表示
---コマンド引数（/mode, /model）の補完にも対応
local M = {}

---現在のカーソル位置からスラッシュコマンドのコンテキストを取得
---@return string? command_name コマンド名（例: "mode"）
---@return boolean is_argument コマンド引数の補完かどうか
---@return number start_col 補完開始位置（0-based）
function M._get_command_context()
  local line = vim.api.nvim_get_current_line()
  local col = vim.api.nvim_win_get_cursor(0)[2]

  -- カーソル位置までの文字列を取得
  local before_cursor = line:sub(1, col)

  -- スラッシュコマンドパターンをマッチ
  -- 例: "/mode ", "/mo", "/"
  local slash_pos = before_cursor:match("^.*()/%s*$")
  if slash_pos then
    -- "/　" の場合（コマンド名補完）
    return nil, false, slash_pos
  end

  -- コマンド名の途中（例: "/mo"）
  local cmd_start, cmd_name = before_cursor:match("^.*()/%s*([%w_-]*)$")
  if cmd_start and cmd_name then
    return cmd_name, false, cmd_start
  end

  -- コマンド引数の補完（例: "/mode "）
  local arg_start, full_cmd = before_cursor:match("^.*()/%s*([%w_-]+)%s+[%w_-]*$")
  if arg_start and full_cmd then
    -- 引数の開始位置を探す
    local arg_col = before_cursor:match("^.*/%s*" .. full_cmd .. "%s+()")
    if arg_col then
      return full_cmd, true, arg_col - 1
    end
  end

  return nil, false, 0
end

---omnifunc実装（Neovim標準）
---@param findstart 0|1 0=補完候補を返す、1=補完開始位置を返す
---@param base string 入力済みの文字列（findstart=0の場合のみ）
---@return number|table findstart=1なら開始位置、findstart=0なら補完候補
function M.omnifunc(findstart, base)
  if findstart == 1 then
    -- Phase 1: 補完開始位置を返す
    local _, _, start_col = M._get_command_context()
    return start_col
  else
    -- Phase 2: 補完候補を返す
    local command_name, is_argument, _ = M._get_command_context()

    if is_argument and command_name then
      -- コマンド引数の補完
      return M._get_argument_completions(command_name, base)
    else
      -- コマンド名の補完
      return M._get_command_completions(base)
    end
  end
end

---コマンド名の補完候補を取得
---@param base string 入力済みの文字列（例: "mo"）
---@return table[] 補完候補のリスト
function M._get_command_completions(base)
  local all_commands = commands.list_all()
  local completions = {}

  for name, cmd in pairs(all_commands) do
    -- baseが空文字列なら全候補、そうでなければ前方一致でフィルタ
    if base == "" or name:lower():find("^" .. vim.pesc(base:lower())) then
      local kind = "[vibing]"
      if cmd.source == "project" then
        kind = "[custom:project]"
      elseif cmd.source == "user" then
        kind = "[custom:user]"
      end

      table.insert(completions, {
        word = name,
        menu = cmd.description,
        kind = kind,
      })
    end
  end

  -- アルファベット順にソート
  table.sort(completions, function(a, b)
    return a.word < b.word
  end)

  return completions
end

---コマンド引数の補完候補を取得
---@param command_name string コマンド名（例: "mode"）
---@param base string 入力済みの文字列（例: "au"）
---@return table[] 補完候補のリスト
function M._get_argument_completions(command_name, base)
  local arg_options = commands.get_argument_completions(command_name)
  if not arg_options then
    return {}
  end

  local completions = {}
  for _, option in ipairs(arg_options) do
    -- baseが空文字列なら全候補、そうでなければ前方一致でフィルタ
    if base == "" or option:lower():find("^" .. vim.pesc(base:lower())) then
      table.insert(completions, {
        word = option,
        menu = string.format("Argument for /%s", command_name),
        kind = "[arg]",
      })
    end
  end

  return completions
end

---チャットバッファにomnifuncを設定
---@param buf number バッファ番号
function M.setup_buffer(buf)
  vim.bo[buf].omnifunc = "v:lua.require('vibing.chat.completion').omnifunc"
end

return M
