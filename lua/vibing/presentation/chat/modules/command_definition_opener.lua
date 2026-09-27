---@class Vibing.Presentation.CommandDefinitionOpener
---`gd` の前段。カーソルが `/name` の上にあれば、その定義ファイル（`SKILL.md` /
---`commands/<name>.md`）を開く。
---
---`gd` のもう一つの意味「カーソル下のファイルのターン差分」は `diff_opener` が持つ。ここが
---`false` を返した場合だけそちらに回る。
local M = {}

---@param buf number チャットバッファ
---@return boolean handled `/name` として処理したか（false なら呼び出し側が差分へ回す）
function M.open(buf)
  local CommandDefinition = require("vibing.application.chat.command_definition")

  local name = CommandDefinition.name_on_line(vim.fn.getline("."), vim.api.nvim_win_get_cursor(0)[2] + 1)
  if not name then
    return false
  end

  local chat_buf = require("vibing.presentation.chat.view").get_chat_buffer(buf)
  local path = CommandDefinition.resolve(name, chat_buf and chat_buf:get_cwd() or nil)
  if path then
    require("vibing.core.utils.file_path").open_file(path)
    return true
  end

  -- ビルトインのスキルはCLIのバイナリ内、`/model` のようなvibing自身のコマンドはLuaのハンドラ
  -- なので開く先が無い。コマンドだと分かっている名前のときだけ理由を伝え、それ以外は黙って
  -- 差分側に回す（パスの断片やURLがここに来る）
  if CommandDefinition.is_known(name) then
    require("vibing.core.utils.notify").info(string.format("/%s has no definition file to open.", name))
    return true
  end

  return false
end

return M
