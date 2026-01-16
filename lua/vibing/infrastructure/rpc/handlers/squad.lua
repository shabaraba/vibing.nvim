local M = {}

---Extract task_ref from frontmatter of a buffer (reads from buffer, not file)
---@param bufnr number
---@return string? task_ref
local function extract_task_ref_from_buffer(bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return nil
  end

  -- Read first 50 lines from buffer (not file)
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  local max_lines = math.min(50, line_count)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, max_lines, false)

  if not lines or #lines == 0 then
    return nil
  end

  if not lines[1] or not lines[1]:match("^---") then
    return nil
  end

  for i = 2, #lines do
    local line = lines[i]
    if line:match("^---") then
      break
    end
    if line:match("^task_ref:") then
      return line:match("task_ref:%s*(.+)")
    end
  end

  return nil
end

---Get squad metadata for a specific buffer
---@param params table { bufnr?: number }
---@return table Squad metadata including squad_name, task_ref
function M.get_squad_info(params)
  local bufnr = params.bufnr or vim.api.nvim_get_current_buf()

  if not vim.api.nvim_buf_is_valid(bufnr) then
    return {
      error = "Invalid buffer number: " .. bufnr,
      bufnr = bufnr,
    }
  end

  local squad_name = vim.b[bufnr].vibing_squad_name
  if not squad_name then
    return {
      error = "Buffer has no squad assignment",
      bufnr = bufnr,
      squad_name = nil,
    }
  end

  local buffer_name = vim.api.nvim_buf_get_name(bufnr)
  return {
    bufnr = bufnr,
    squad_name = squad_name,
    buffer_name = buffer_name, -- nvim_buf_get_nameの結果（パス形式だが開くのはbufnrを使う）
    task_ref = extract_task_ref_from_buffer(bufnr),
  }
end

---List all active squads in current Neovim instance
---@param params table
---@return table Array of active squads with metadata
function M.list_squads(params)
  local Registry = require("vibing.infrastructure.squad.registry")
  local active_squads = Registry.get_all_active()

  local squads = {}
  for squad_name, bufnr in pairs(active_squads) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      local buffer_name = vim.api.nvim_buf_get_name(bufnr)
      table.insert(squads, {
        squad_name = squad_name,
        bufnr = bufnr,
        buffer_name = buffer_name,
        task_ref = extract_task_ref_from_buffer(bufnr),
      })
    end
  end

  return {
    squads = squads,
    count = #squads,
  }
end

---Find buffer number for a specific squad by name
---@param params table { squad_name: string }
---@return table Result with bufnr if found, error message otherwise
function M.find_squad_buffer(params)
  if not params.squad_name then
    return {
      error = "squad_name is required",
    }
  end

  local Registry = require("vibing.infrastructure.squad.registry")
  local active_squads = Registry.get_all_active()

  local bufnr = active_squads[params.squad_name]
  if not bufnr then
    return {
      squad_name = params.squad_name,
      bufnr = nil,
      found = false,
    }
  end

  -- Validate buffer still exists
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return {
      squad_name = params.squad_name,
      bufnr = bufnr,
      found = false,
      error = "Squad buffer no longer exists",
    }
  end

  local buffer_name = vim.api.nvim_buf_get_name(bufnr)
  return {
    squad_name = params.squad_name,
    bufnr = bufnr,
    buffer_name = buffer_name,
    found = true,
  }
end

return M
