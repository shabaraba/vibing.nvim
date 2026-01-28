---@class Vibing.Utils.Mote.Command
---moteコマンドの構築と実行
local M = {}

---moteコマンドのベース引数を生成
---mote v0.2.1+: -d/--context-dirでスタンドアロンモード（グローバル設定不要）
---プロジェクトローカルに完全に独立して動作
---@param config Vibing.MoteConfig mote設定
---@return string[] コマンドライン引数の配列
function M.build_base_args(config)
  local Binary = require("vibing.core.utils.mote.binary")
  local Context = require("vibing.core.utils.mote.context")

  local abs_ignore_file = vim.fn.fnamemodify(config.ignore_file, ":p")
  local cmd = { Binary.get_path(), "--ignore-file", abs_ignore_file }

  -- -d/--context-dirでスタンドアロンモード
  local project = config.project or Context.get_project_name()
  local context_dir = Context.build_dir_path(project, config.context)
  if context_dir then
    table.insert(cmd, "-d")
    table.insert(cmd, context_dir)
  end

  return cmd
end

---moteコマンドを実行し結果をコールバックで返す
---@param args string[] コマンドライン引数
---@param cwd string|nil 作業ディレクトリ（nilの場合は現在のディレクトリ）
---@param on_success fun(stdout: string) 成功時のコールバック
---@param on_error fun(error: string) エラー時のコールバック
function M.run(args, cwd, on_success, on_error)
  local opts = { text = true }
  if cwd then
    opts.cwd = cwd
  end

  vim.system(args, opts, function(obj)
    vim.schedule(function()
      if obj.code ~= 0 then
        on_error(obj.stderr or "Unknown error")
        return
      end
      on_success(obj.stdout or "")
    end)
  end)
end

return M
