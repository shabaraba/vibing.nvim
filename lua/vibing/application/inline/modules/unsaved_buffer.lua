---未保存バッファのハンドリングモジュール
---未保存バッファに対するプロンプトとパーミッション設定の調整

---@class Vibing.UnsavedBufferModule
local M = {}

---Apply unsaved buffer handling to prompt and opts
---@param prompt string Original prompt
---@param opts table Options table (will be modified)
---@param is_modified boolean Whether buffer has unsaved changes
---@return string Modified prompt
function M.apply_handling(prompt, opts, is_modified)
  if not is_modified then
    return prompt
  end

  -- Modify prompt
  prompt = prompt
    .. "\n\nIMPORTANT: This buffer has unsaved changes. You MUST use mcp__vibing-nvim__nvim_set_buffer tool to edit the buffer directly, NOT the Edit or Write tools. This ensures the changes are applied to the current buffer state, not the saved file."

  -- Initialize permission lists if needed
  if not opts.permissions_allow then
    opts.permissions_allow = {}
  end
  if not opts.permissions_deny then
    opts.permissions_deny = {}
  end

  -- Remove Edit/Write from allow list to prevent conflicts
  opts.permissions_allow = vim.tbl_filter(function(tool)
    return tool ~= "Edit" and tool ~= "Write"
  end, opts.permissions_allow)

  -- Deny Edit/Write tools for unsaved buffers
  if not vim.tbl_contains(opts.permissions_deny, "Edit") then
    table.insert(opts.permissions_deny, "Edit")
  end
  if not vim.tbl_contains(opts.permissions_deny, "Write") then
    table.insert(opts.permissions_deny, "Write")
  end

  -- Ensure nvim_set_buffer is allowed
  if not vim.tbl_contains(opts.permissions_allow, "mcp__vibing-nvim__nvim_set_buffer") then
    table.insert(opts.permissions_allow, "mcp__vibing-nvim__nvim_set_buffer")
  end

  return prompt
end

---現在のバッファが未保存かどうかを判定
---@param bufnr? number Buffer number (defaults to current buffer)
---@return boolean
function M.is_modified(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  return vim.bo[bufnr].modified
end

return M
