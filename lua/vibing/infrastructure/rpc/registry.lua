---@class Vibing.RpcRegistry
---Instance registry for managing multiple Neovim instances with vibing.nvim RPC servers
---Tracks running instances by PID, port, and working directory
local M = {}

local uv = vim.loop

---Get registry directory path
---Uses vim.fn.stdpath("data") which handles platform differences:
---  - Linux/macOS: ~/.local/share/nvim (or $XDG_DATA_HOME/nvim)
---  - Windows: ~/AppData/Local/nvim-data
---Note: Must match getRegistryPath() in mcp-server/src/handlers/instances.ts
---@return string path Registry directory path
local function get_registry_dir()
  local data_dir = vim.fn.stdpath("data")
  return data_dir .. "/vibing-instances"
end

---Get registry file path for current instance
---@return string path Registry file path
local function get_instance_file()
  local pid = vim.fn.getpid()
  return get_registry_dir() .. "/" .. pid .. ".json"
end

---Ensure registry directory exists
---@return boolean success Whether directory was created or already exists
local function ensure_registry_dir()
  local dir = get_registry_dir()
  local stat = uv.fs_stat(dir)
  if not stat then
    local ok, err = vim.fn.mkdir(dir, "p")
    if ok == 0 then
      vim.notify(
        string.format("Failed to create registry directory: %s", err or "unknown error"),
        vim.log.levels.ERROR
      )
      return false
    end
  end
  return true
end

---Register current instance
---@param port number RPC server port
---@return boolean success Whether registration succeeded
function M.register(port)
  if not ensure_registry_dir() then
    return false
  end

  local instance_data = {
    pid = vim.fn.getpid(),
    port = port,
    cwd = vim.fn.getcwd(),
    started_at = os.time(),
  }

  local file_path = get_instance_file()
  local json_str = vim.json.encode(instance_data)

  -- Write to file synchronously
  local ok, err = pcall(vim.fn.writefile, { json_str }, file_path)
  if not ok then
    vim.notify(
      string.format("Failed to write registry file: %s", err or "unknown error"),
      vim.log.levels.ERROR
    )
    return false
  end

  return true
end

---Unregister current instance
---@return boolean success Whether unregistration succeeded
function M.unregister()
  local file_path = get_instance_file()
  local stat = uv.fs_stat(file_path)

  if stat then
    local ok, err = pcall(vim.fn.delete, file_path)
    if not ok then
      vim.notify(
        string.format("Failed to delete registry file: %s", err or "unknown error"),
        vim.log.levels.WARN
      )
      return false
    end
  end

  return true
end

---List all registered instances
---@return table instances Array of instance data
function M.list()
  local dir = get_registry_dir()
  local stat = uv.fs_stat(dir)

  if not stat then
    return {}
  end

  local ok, files = pcall(vim.fn.readdir, dir)
  if not ok or not files then
    return {}
  end

  local instances = {}

  for _, file in ipairs(files) do
    if file:match("%.json$") then
      local file_path = dir .. "/" .. file
      local content_ok, content = pcall(vim.fn.readfile, file_path)

      if content_ok and content and #content > 0 then
        local json_ok, data = pcall(vim.json.decode, content[1])

        if json_ok and data and data.pid then
          -- Check if process is still alive
          local alive = pcall(uv.kill, data.pid, 0)

          if alive then
            table.insert(instances, data)
          else
            -- Process is dead, clean up stale registry
            pcall(vim.fn.delete, file_path)
          end
        end
      end
    end
  end

  -- Sort by started_at (newest first)
  table.sort(instances, function(a, b)
    return (a.started_at or 0) > (b.started_at or 0)
  end)

  return instances
end

---Check if a port is already in use by another instance
---@param port number Port to check
---@param instances? table Optional cached instances list (from M.list())
---@return boolean in_use Whether port is in use
function M.is_port_in_use(port, instances)
  -- Use cached instances if provided, otherwise fetch fresh list
  instances = instances or M.list()

  for _, instance in ipairs(instances) do
    if instance.port == port then
      return true
    end
  end

  return false
end

return M
