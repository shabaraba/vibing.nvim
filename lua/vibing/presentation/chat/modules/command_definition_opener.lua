---@class Vibing.Presentation.CommandDefinitionOpener
---`gd` の前段。カーソルが `/name` の上にあれば、その定義ファイル（`SKILL.md` /
---`commands/<name>.md`）を開く。
---
---`gd` の本来の意味は「カーソル下のファイルのターン差分」で、そちらは `diff_opener` が持つ。
---ここが `false` を返した場合だけ差分側に回るので、判定は必ずこちらが先に走る。
---`diff_opener` は節の中ならカーソル位置に関係なく直近のpatchを開くため、順序を逆にすると
---`/name` の上で押しても差分フロートが出る。
local M = {}

local CommandDefinition = require("vibing.application.chat.command_definition")

---@param buf number チャットバッファ
---@return boolean handled `/name` として処理したか（false のとき呼び出し側が差分へ回す）
function M.open(buf)
  -- バッファ行全体を取る（ソフト折り返しでも名前が切れない）
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

  -- ビルトインのスキルはCLIのバイナリ内にあり、`/model` のようなvibing自身のコマンドは
  -- Luaのハンドラなので、開く先が無い。コマンドだと分かっている名前のときだけ理由を伝える。
  -- それ以外は黙って差分側に回す（パスの断片やURLがここに来る）
  if CommandDefinition.is_known(name) then
    require("vibing.core.utils.notify").info(string.format("/%s has no definition file to open.", name))
    return true
  end

  return false
end

return M
