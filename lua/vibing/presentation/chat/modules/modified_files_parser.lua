local M = {}

---チャットバッファからModified Filesセクションをパースして、最新のファイル一覧を取得
---@param buf number バッファ番号
---@return string[] modified_files 変更されたファイルのパス一覧
function M.parse_latest_modified_files(buf)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return {}
  end

  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local modified_files = {}
  local in_modified_section = false
  local last_section_files = {}

  for _, line in ipairs(lines) do
    -- Modified Filesセクションの開始を検出
    if line:match("^## Modified Files") or line:match("^### Modified Files") then
      in_modified_section = true
      last_section_files = {}  -- 新しいセクションが見つかったらリセット
    -- セクション終了を検出（次のヘッダーまたは区切り線）
    elseif in_modified_section and (line:match("^##") or line:match("^%-%-%-")) then
      in_modified_section = false
    -- Modified Filesセクション内でファイルを抽出
    elseif in_modified_section then
      -- マークダウンリスト形式: - `filename` または - filename
      local file = line:match("^%s*%-%s*`([^`]+)`") or line:match("^%s*%-%s*(.+)$")
      if file and file ~= "" then
        table.insert(last_section_files, file)
      end
      -- プレーンテキスト形式（バッククォートなし）
      if not file then
        file = line:match("^([^%s%-#].*%.%w+)$")  -- 拡張子を持つファイル名
        if file and file ~= "" then
          table.insert(last_section_files, file)
        end
      end
    end
  end

  -- 最後に見つかったModified Filesセクションのファイルを返す
  return last_section_files
end

return M
