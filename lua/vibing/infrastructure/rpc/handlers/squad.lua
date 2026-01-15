local M = {}

---Get squad metadata for a specific buffer
---@param params table { bufnr?: number }
---@return table Squad metadata including squad_name, task_type
function M.get_squad_info(params)
  local bufnr = params.bufnr or vim.api.nvim_get_current_buf()

  -- Validate buffer exists
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return {
      error = "Invalid buffer number: " .. bufnr,
      bufnr = bufnr,
    }
  end

  -- Get squad_name from buffer-local variable
  local squad_name = vim.b[bufnr].vibing_squad_name
  if not squad_name then
    return {
      error = "Buffer has no squad assignment",
      bufnr = bufnr,
      squad_name = nil,
    }
  end

  -- Try to read frontmatter from buffer to get full metadata
  local file_path = vim.api.nvim_buf_get_name(bufnr)
  local squad_info = {
    bufnr = bufnr,
    squad_name = squad_name,
    file_path = file_path,
  }

  -- Try to read frontmatter (task_type, task_ref, etc.)
  if file_path and file_path ~= "" then
    local lines = vim.fn.readfile(file_path, "", 50)
    if lines and #lines > 0 then
      -- Check if file has YAML frontmatter
      if lines[1]:match("^---") then
        for i = 2, #lines do
          local line = lines[i]
          -- End of frontmatter
          if line:match("^---") then
            break
          end
          -- Extract task_type if present
          if line:match("^task_type:") then
            local task_type = line:match("task_type:%s*(.+)")
            squad_info.task_type = task_type
          end
          -- Extract task_ref if present
          if line:match("^task_ref:") then
            local task_ref = line:match("task_ref:%s*(.+)")
            squad_info.task_ref = task_ref
          end
        end
      end
    end
  end

  return squad_info
end

---List all active squads in current Neovim instance
---@param params table
---@return table Array of active squads with metadata
function M.list_squads(params)
  local Registry = require("vibing.infrastructure.squad.registry")

  -- Get all active squads from registry
  local active_squads = Registry.get_all_active()

  -- Build detailed squad list
  local squads = {}
  for squad_name, bufnr in pairs(active_squads) do
    -- Validate buffer still exists
    if vim.api.nvim_buf_is_valid(bufnr) then
      local file_path = vim.api.nvim_buf_get_name(bufnr)
      local squad_entry = {
        squad_name = squad_name,
        bufnr = bufnr,
        file_path = file_path,
      }

      -- Try to read task_type from frontmatter
      if file_path and file_path ~= "" then
        local lines = vim.fn.readfile(file_path, "", 50)
        if lines and #lines > 0 and lines[1]:match("^---") then
          for i = 2, #lines do
            local line = lines[i]
            if line:match("^---") then
              break
            end
            if line:match("^task_type:") then
              local task_type = line:match("task_type:%s*(.+)")
              squad_entry.task_type = task_type
            end
            if line:match("^task_ref:") then
              local task_ref = line:match("task_ref:%s*(.+)")
              squad_entry.task_ref = task_ref
            end
          end
        end
      end

      table.insert(squads, squad_entry)
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
