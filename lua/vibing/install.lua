---@class Vibing.Install
---プラグインインストール・ビルドユーティリティ
---Lazy.nvimのbuildフックから呼び出されるビルド関数を提供
local M = {}

---Get plugin root directory
---@return string
local function get_plugin_root()
  local source = debug.getinfo(1, "S").source:sub(2)
  local plugin_root = vim.fn.fnamemodify(source, ":h:h:h")
  return plugin_root
end

---Check if command exists
---@param cmd string
---@return boolean
local function command_exists(cmd)
  return vim.fn.executable(cmd) == 1
end

---Get Node.js version
---@return number? major_version
local function get_node_version()
  if not command_exists("node") then
    return nil
  end

  local version_output = vim.fn.system("node -v")
  if vim.v.shell_error ~= 0 then
    return nil
  end

  local major = version_output:match("v(%d+)")
  return major and tonumber(major) or nil
end

---Print build message
---@param msg string
---@param level? string "info" | "warn" | "error"
local function print_build(msg, level)
  level = level or "info"
  local prefix = "[vibing.nvim]"

  if level == "error" then
    vim.notify(prefix .. " " .. msg, vim.log.levels.ERROR)
  elseif level == "warn" then
    vim.notify(prefix .. " " .. msg, vim.log.levels.WARN)
  else
    vim.notify(prefix .. " " .. msg, vim.log.levels.INFO)
  end
end

---Build MCP server (synchronous)
---@return boolean success
function M.build()
  local plugin_root = get_plugin_root()
  local mcp_dir = plugin_root .. "/mcp-server"

  print_build("Building MCP server...")

  -- Check Node.js
  if not command_exists("node") then
    print_build("Error: Node.js not found. Please install Node.js 18+ from https://nodejs.org/", "error")
    return false
  end

  local node_version = get_node_version()
  if node_version and node_version < 18 then
    print_build(string.format("Warning: Node.js 18+ recommended (found: v%d)", node_version), "warn")
  end

  -- Check npm
  if not command_exists("npm") then
    print_build("Error: npm not found. Please install npm", "error")
    return false
  end

  -- Check MCP directory
  if vim.fn.isdirectory(mcp_dir) == 0 then
    print_build("Error: MCP server directory not found: " .. mcp_dir, "error")
    return false
  end

  -- Build command
  local cmd = string.format(
    "cd %s && npm install --silent && npm run build --silent",
    vim.fn.shellescape(mcp_dir)
  )

  -- Execute build
  print_build("Installing dependencies and building TypeScript...")
  local output = vim.fn.system(cmd)
  local exit_code = vim.v.shell_error

  if exit_code ~= 0 then
    print_build("Build failed. Output:", "error")
    print(output)
    return false
  end

  -- Verify build succeeded
  local dist_index = mcp_dir .. "/dist/index.js"
  if vim.fn.filereadable(dist_index) == 1 then
    print_build("✓ MCP server built successfully")

    -- Register MCP server in ~/.claude.json
    local register_script = plugin_root .. "/bin/register-mcp.mjs"
    if vim.fn.filereadable(register_script) == 1 then
      print_build("Registering MCP server in ~/.claude.json...")
      local register_output = vim.fn.system("node " .. vim.fn.shellescape(register_script))
      if vim.v.shell_error == 0 then
        print_build("✓ MCP server registered")
      else
        print_build("Warning: MCP registration failed", "warn")
        print_build(register_output, "warn")
      end
    end

    return true
  else
    print_build("Build failed: dist/index.js not found", "error")
    return false
  end
end

---Build MCP server (async with callback)
---@param callback? function Callback function called with success status
function M.build_async(callback)
  local plugin_root = get_plugin_root()
  local mcp_dir = plugin_root .. "/mcp-server"

  print_build("Building MCP server...")

  -- Check prerequisites
  if not command_exists("node") then
    print_build("Error: Node.js not found", "error")
    if callback then
      callback(false)
    end
    return
  end

  if not command_exists("npm") then
    print_build("Error: npm not found", "error")
    if callback then
      callback(false)
    end
    return
  end

  if vim.fn.isdirectory(mcp_dir) == 0 then
    print_build("Error: MCP server directory not found", "error")
    if callback then
      callback(false)
    end
    return
  end

  -- Build command
  local cmd = string.format(
    "cd %s && npm install --silent && npm run build --silent",
    vim.fn.shellescape(mcp_dir)
  )

  print_build("Installing dependencies and building TypeScript...")

  -- Execute async
  vim.fn.jobstart(cmd, {
    on_exit = function(_, exit_code)
      if exit_code == 0 then
        local dist_index = mcp_dir .. "/dist/index.js"
        if vim.fn.filereadable(dist_index) == 1 then
          vim.schedule(function()
            print_build("✓ MCP server built successfully")

            -- Register MCP server in ~/.claude.json
            local register_script = plugin_root .. "/bin/register-mcp.mjs"
            if vim.fn.filereadable(register_script) == 1 then
              print_build("Registering MCP server in ~/.claude.json...")
              vim.fn.jobstart("node " .. vim.fn.shellescape(register_script), {
                on_exit = function(_, reg_exit_code)
                  vim.schedule(function()
                    if reg_exit_code == 0 then
                      print_build("✓ MCP server registered")
                    else
                      print_build("Warning: MCP registration failed", "warn")
                    end
                    -- Call callback after registration completes (success or failure)
                    if callback then
                      callback(exit_code == 0 and reg_exit_code == 0)
                    end
                  end)
                end,
              })
            else
              -- No registration script, call callback immediately
              if callback then
                callback(true)
              end
            end
          end)
        else
          vim.schedule(function()
            print_build("Build failed: dist/index.js not found", "error")
          end)
          if callback then
            callback(false)
          end
        end
      else
        vim.schedule(function()
          print_build("Build failed with exit code: " .. exit_code, "error")
        end)
        if callback then
          callback(false)
        end
      end
    end,
  })
end

---Check if MCP server is built
---@return boolean
function M.is_built()
  local plugin_root = get_plugin_root()
  local dist_index = plugin_root .. "/mcp-server/dist/index.js"
  return vim.fn.filereadable(dist_index) == 1
end

return M
