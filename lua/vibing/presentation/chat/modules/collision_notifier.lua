---@class Vibing.Presentation.Chat.CollisionNotifier
---衝突時のバッファ内通知
local M = {}

---衝突通知コメントをfrontmatter直後に挿入
---@param bufnr number バッファ番号
---@param notice_message string 通知メッセージ
function M.insert_collision_notice(bufnr, notice_message)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

  -- frontmatterの終端（"---"）を検索
  local frontmatter_end = nil
  local in_frontmatter = false

  for i, line in ipairs(lines) do
    if i == 1 and line:match("^%-%-%-$") then
      in_frontmatter = true
    elseif in_frontmatter and line:match("^%-%-%-$") then
      frontmatter_end = i
      break
    end
  end

  if not frontmatter_end then
    -- frontmatterがない場合は先頭に挿入
    frontmatter_end = 0
  end

  -- 通知コメントを生成
  local comment = string.format("<!-- vibing.nvim: %s -->", notice_message)

  -- frontmatter直後に挿入
  vim.api.nvim_buf_set_lines(bufnr, frontmatter_end, frontmatter_end, false, { "", comment, "" })
end

return M
