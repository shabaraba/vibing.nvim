---@class Vibing.UsageDisplay
---チャットバッファ先頭にClaudeプランの利用率をvirtual textで表示
local M = {}

---@type table<number, { ns_id: number }>
local state = {}

local cached_claude_path = nil

---`claude -p "/usage"` の出力テキストからsession/week使用率を抜き出す
---@param text string
---@return string|nil
local function parse_summary(text)
  if type(text) ~= "string" then
    return nil
  end

  local session = text:match("Current session: ([^\n]+)")
  local week = text:match("Current week %(all models%): ([^\n]+)")

  if not session and not week then
    return nil
  end

  local parts = {}
  if session then
    table.insert(parts, "session " .. session)
  end
  if week then
    table.insert(parts, "week " .. week)
  end

  return table.concat(parts, " / ")
end

---バッファ先頭に利用率を仮想行として表示（既存表示は上書き）
---@param bufnr number
---@param text string
function M.show(bufnr, text)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  local ns_id = state[bufnr] and state[bufnr].ns_id or vim.api.nvim_create_namespace("vibing_usage_" .. bufnr)
  vim.api.nvim_buf_clear_namespace(bufnr, ns_id, 0, -1)

  vim.api.nvim_buf_set_extmark(bufnr, ns_id, 0, 0, {
    virt_lines = { { { "󰊚 " .. text, "Comment" } } },
    virt_lines_above = true,
  })

  state[bufnr] = { ns_id = ns_id }
end

---バッファの利用率表示をクリア
---@param bufnr number
function M.clear(bufnr)
  local entry = state[bufnr]
  if entry and vim.api.nvim_buf_is_valid(bufnr) then
    vim.api.nvim_buf_clear_namespace(bufnr, entry.ns_id, 0, -1)
  end
  state[bufnr] = nil
end

---裏で`claude -p "/usage"`を実行し、結果をバッファ先頭に表示する
---@param bufnr number
---@param cwd string|nil
function M.refresh(bufnr, cwd)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  if not cached_claude_path then
    cached_claude_path = vim.fn.exepath("claude")
    if cached_claude_path == "" then
      cached_claude_path = nil
      return
    end
  end

  local cmd = { cached_claude_path, "-p", "/usage", "--output-format", "json" }
  local opts = { text = true }
  if cwd then
    opts.cwd = cwd
  end

  vim.system(cmd, opts, function(obj)
    vim.schedule(function()
      if obj.code ~= 0 or not obj.stdout then
        return
      end

      local ok, decoded = pcall(vim.json.decode, obj.stdout)
      if not ok or not decoded or type(decoded.result) ~= "string" then
        return
      end

      local summary = parse_summary(decoded.result)
      if summary then
        M.show(bufnr, summary)
      end
    end)
  end)
end

return M
