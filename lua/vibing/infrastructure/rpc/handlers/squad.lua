local M = {}

---Extract task_ref from frontmatter of a file
---@param file_path string
---@return string? task_ref
local function extract_task_ref(file_path)
  if not file_path or file_path == "" then
    return nil
  end

  local lines = vim.fn.readfile(file_path, "", 50)
  if not lines or #lines == 0 or not lines[1]:match("^---") then
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

  local file_path = vim.api.nvim_buf_get_name(bufnr)
  return {
    bufnr = bufnr,
    squad_name = squad_name,
    file_path = file_path,
    task_ref = extract_task_ref(file_path),
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
      local file_path = vim.api.nvim_buf_get_name(bufnr)
      table.insert(squads, {
        squad_name = squad_name,
        bufnr = bufnr,
        file_path = file_path,
        task_ref = extract_task_ref(file_path),
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

  local file_path = vim.api.nvim_buf_get_name(bufnr)
  return {
    squad_name = params.squad_name,
    bufnr = bufnr,
    file_path = file_path,
    found = true,
  }
end

return M
