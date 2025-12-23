---@class Vibing.McpSetup
---MCP統合の自動セットアップユーティリティ
---claude.jsonへの設定追加、MCPサーバービルドを自動化
local M = {}

local notify = require("vibing.utils.notify")

---Get plugin root directory
---@return string
local function get_plugin_root()
  local source = debug.getinfo(1, "S").source:sub(2)
  local plugin_root = vim.fn.fnamemodify(source, ":h:h:h:h")
  return plugin_root
end

---Check if MCP server is built
---@return boolean
function M.is_mcp_built()
  local plugin_root = get_plugin_root()
  local dist_index = plugin_root .. "/mcp-server/dist/index.js"
  return vim.fn.filereadable(dist_index) == 1
end

---Build MCP server
---@param callback? function コールバック関数（成功時にtrueを渡す）
function M.build_mcp_server(callback)
  local plugin_root = get_plugin_root()
  local mcp_dir = plugin_root .. "/mcp-server"

  if vim.fn.isdirectory(mcp_dir) == 0 then
    notify.error("MCP server directory not found: " .. mcp_dir)
    if callback then
      callback(false)
    end
    return
  end

  notify.info("Building MCP server...")

  -- Check if npm is available
  local npm_check = vim.fn.executable("npm")
  if npm_check == 0 then
    notify.error("npm not found. Please install Node.js and npm.")
    if callback then
      callback(false)
    end
    return
  end

  -- Build command
  local cmd = string.format("cd %s && npm install && npm run build", vim.fn.shellescape(mcp_dir))

  vim.fn.jobstart(cmd, {
    on_exit = function(_, exit_code)
      if exit_code == 0 then
        vim.schedule(function()
          notify.info("MCP server built successfully")

          -- Register MCP server in ~/.claude.json
          local register_script = plugin_root .. "/bin/register-mcp.mjs"
          if vim.fn.filereadable(register_script) == 1 then
            notify.info("Registering MCP server in ~/.claude.json...")
            vim.fn.jobstart("node " .. vim.fn.shellescape(register_script), {
              on_exit = function(_, reg_exit_code)
                vim.schedule(function()
                  if reg_exit_code == 0 then
                    notify.info("MCP server registered successfully")
                  else
                    notify.warn("MCP registration failed")
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
        notify.error("Failed to build MCP server (exit code: " .. exit_code .. ")")
        if callback then
          callback(false)
        end
      end
    end,
    on_stderr = function(_, data)
      if data and #data > 0 then
        for _, line in ipairs(data) do
          if line ~= "" then
            vim.schedule(function()
              notify.warn("Build: " .. line)
            end)
          end
        end
      end
    end,
  })
end

---Read claude.json file
---@param path string
---@return table?
local function read_claude_json(path)
  if vim.fn.filereadable(path) == 0 then
    return nil
  end

  local content = vim.fn.readfile(path)
  local json_str = table.concat(content, "\n")

  local ok, data = pcall(vim.json.decode, json_str)
  if not ok then
    notify.warn("Failed to parse " .. path .. ": " .. tostring(data))
    return nil
  end

  return data
end

---Write claude.json file
---@param path string
---@param data table
---@return boolean
local function write_claude_json(path, data)
  local json_str = vim.json.encode(data)

  -- Pretty print JSON
  json_str = vim.fn.system("jq .", json_str)
  if vim.v.shell_error ~= 0 then
    -- Fallback if jq is not available
    json_str = vim.json.encode(data)
  end

  local ok, err = pcall(vim.fn.writefile, vim.split(json_str, "\n"), path)
  if not ok then
    notify.error("Failed to write " .. path .. ": " .. tostring(err))
    return false
  end

  return true
end

---Setup claude.json configuration
---@param opts? {force?: boolean, port?: number} オプション
---@return boolean success
function M.setup_claude_json(opts)
  opts = opts or {}
  local force = opts.force or false
  local port = opts.port or 9876

  local claude_json_path = vim.fn.expand("~/.claude.json")
  local plugin_root = get_plugin_root()
  local mcp_server_path = plugin_root .. "/mcp-server/dist/index.js"

  -- Check if MCP server is built
  if vim.fn.filereadable(mcp_server_path) == 0 then
    notify.warn("MCP server not built. Run :VibingBuildMcp first.")
    return false
  end

  -- Read existing claude.json
  local config = read_claude_json(claude_json_path) or {}

  -- Initialize mcpServers if not present
  if not config.mcpServers then
    config.mcpServers = {}
  end

  -- Check if vibing-nvim already configured
  if config.mcpServers["vibing-nvim"] and not force then
    notify.info("vibing-nvim already configured in " .. claude_json_path)
    notify.info("Use force=true to overwrite")
    return true
  end

  -- Add vibing-nvim MCP server
  config.mcpServers["vibing-nvim"] = {
    command = "node",
    args = { mcp_server_path },
    env = {
      VIBING_RPC_PORT = tostring(port),
    },
  }

  -- Write updated config
  if write_claude_json(claude_json_path, config) then
    notify.info("Updated " .. claude_json_path)
    notify.info("vibing-nvim MCP server configured on port " .. port)
    return true
  end

  return false
end

---Interactive setup wizard
---@param config? Vibing.Config
function M.setup_wizard(config)
  config = config or {}
  local mcp_config = config.mcp or {}
  local port = mcp_config.rpc_port or 9876

  -- Step 1: Check if MCP server is built
  if not M.is_mcp_built() then
    vim.ui.select({ "Yes", "No" }, {
      prompt = "MCP server not built. Build now?",
    }, function(choice)
      if choice == "Yes" then
        M.build_mcp_server(function(success)
          if success then
            -- Continue to step 2
            vim.schedule(function()
              M._setup_wizard_step2(port)
            end)
          end
        end)
      end
    end)
  else
    M._setup_wizard_step2(port)
  end
end

---Setup wizard step 2: Configure claude.json
---@param port number
function M._setup_wizard_step2(port)
  local claude_json_path = vim.fn.expand("~/.claude.json")
  local exists = vim.fn.filereadable(claude_json_path) == 1

  local prompt
  if exists then
    prompt = string.format("Update %s with vibing-nvim MCP server (port %d)?", claude_json_path, port)
  else
    prompt = string.format("Create %s with vibing-nvim MCP server (port %d)?", claude_json_path, port)
  end

  vim.ui.select({ "Yes", "No" }, {
    prompt = prompt,
  }, function(choice)
    if choice == "Yes" then
      M.setup_claude_json({ force = true, port = port })
    end
  end)
end

---Auto-setup on plugin load (if configured)
---@param config Vibing.Config
function M.auto_setup(config)
  if not config.mcp or not config.mcp.enabled then
    return
  end

  -- Check auto_setup option
  if not config.mcp.auto_setup then
    return
  end

  -- Build MCP server if needed
  if not M.is_mcp_built() then
    notify.info("MCP server not built. Building...")
    M.build_mcp_server(function(success)
      if success and config.mcp.auto_configure_claude_json then
        vim.schedule(function()
          M.setup_claude_json({ port = config.mcp.rpc_port })
        end)
      end
    end)
  elseif config.mcp.auto_configure_claude_json then
    -- MCP server already built, just configure claude.json
    M.setup_claude_json({ port = config.mcp.rpc_port })
  end
end

return M
