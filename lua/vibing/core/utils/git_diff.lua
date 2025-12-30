---@class Vibing.Utils.GitDiff
---Git diff表示のユーティリティ
local M = {}

---ファイルのgit diffを表示
---delta が利用可能な場合は delta を使用、そうでない場合は git diff の出力をそのまま表示
---@param file_path string ファイルパス（絶対パス）
function M.show_diff(file_path)
  -- ファイルパスを正規化
  local normalized_path = vim.fn.fnamemodify(file_path, ":p")

  -- delta が利用可能かチェック
  local has_delta = vim.fn.executable("delta") == 1

  -- コマンドを構築
  local cmd
  if has_delta then
    cmd = string.format("git diff HEAD %s | delta", vim.fn.shellescape(normalized_path))
  else
    cmd = string.format("git diff HEAD %s", vim.fn.shellescape(normalized_path))
  end

  -- 非同期でコマンドを実行
  vim.system({ "sh", "-c", cmd }, { text = true }, function(obj)
    vim.schedule(function()
      if obj.code ~= 0 then
        -- エラーハンドリング
        local error_msg = obj.stderr or "Unknown error"
        if error_msg:match("not a git repository") then
          vim.notify("[vibing] Not a git repository", vim.log.levels.ERROR)
        elseif error_msg:match("no such file") or error_msg:match("does not exist") then
          vim.notify("[vibing] File not in git: " .. file_path, vim.log.levels.ERROR)
        else
          vim.notify("[vibing] Git diff failed: " .. error_msg, vim.log.levels.ERROR)
        end
        return
      end

      local output = obj.stdout or ""
      if output == "" or output:match("^%s*$") then
        vim.notify("[vibing] No changes to show", vim.log.levels.INFO)
        return
      end

      -- 一時バッファを作成
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_option(buf, "buftype", "nofile")
      vim.api.nvim_buf_set_option(buf, "bufhidden", "wipe")
      vim.api.nvim_buf_set_option(buf, "filetype", "diff")
      vim.api.nvim_buf_set_option(buf, "modifiable", true)

      -- バッファに内容を設定
      local lines = vim.split(output, "\n")
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
      vim.api.nvim_buf_set_option(buf, "modifiable", false)

      -- 現在のウィンドウで開く
      vim.api.nvim_set_current_buf(buf)

      -- q と <Esc> でバッファを閉じるキーマップを設定
      vim.keymap.set("n", "q", function()
        vim.api.nvim_buf_delete(buf, { force = true })
      end, { buffer = buf, noremap = true, silent = true })

      vim.keymap.set("n", "<Esc>", function()
        vim.api.nvim_buf_delete(buf, { force = true })
      end, { buffer = buf, noremap = true, silent = true })
    end)
  end)
end

return M
