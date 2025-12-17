local Base = require("vibing.adapters.base")

---@class Vibing.AgentSDKAdapter : Vibing.Adapter
---@field _handle table?
---@field _plugin_root string
local AgentSDK = setmetatable({}, { __index = Base })
AgentSDK.__index = AgentSDK

---@param config Vibing.Config
---@return Vibing.AgentSDKAdapter
function AgentSDK:new(config)
  local instance = Base.new(self, config)
  setmetatable(instance, AgentSDK)
  instance.name = "agent_sdk"
  instance._handle = nil
  -- Find plugin root directory
  local source = debug.getinfo(1, "S").source:sub(2)
  instance._plugin_root = vim.fn.fnamemodify(source, ":h:h:h:h")
  return instance
end

---Get the wrapper script path
---@return string
function AgentSDK:get_wrapper_path()
  return self._plugin_root .. "/bin/agent-wrapper.mjs"
end

---@param prompt string
---@param opts Vibing.AdapterOpts
---@return string[]
function AgentSDK:build_command(prompt, opts)
  local cmd = { "node", self:get_wrapper_path() }

  table.insert(cmd, "--cwd")
  table.insert(cmd, vim.fn.getcwd())

  -- Add mode from config if available
  if self._config.agent and self._config.agent.default_mode then
    table.insert(cmd, "--mode")
    table.insert(cmd, self._config.agent.default_mode)
  end

  -- Add model from config if available
  if self._config.agent and self._config.agent.default_model then
    table.insert(cmd, "--model")
    table.insert(cmd, self._config.agent.default_model)
  end

  -- Add context files
  for _, ctx in ipairs(opts.context or {}) do
    if ctx:match("^@file:") then
      local path = ctx:sub(7)
      table.insert(cmd, "--context")
      table.insert(cmd, path)
    end
  end

  -- Add session ID for resuming
  if self._session_id then
    table.insert(cmd, "--session")
    table.insert(cmd, self._session_id)
  end

  -- Add permissions
  local vibing = require("vibing")
  local config = vibing.get_config()
  if config.permissions then
    if config.permissions.allow and #config.permissions.allow > 0 then
      table.insert(cmd, "--allow")
      table.insert(cmd, table.concat(config.permissions.allow, ","))
    end
    if config.permissions.deny and #config.permissions.deny > 0 then
      table.insert(cmd, "--deny")
      table.insert(cmd, table.concat(config.permissions.deny, ","))
    end
  end

  table.insert(cmd, "--prompt")
  table.insert(cmd, prompt)

  return cmd
end

---@param prompt string
---@param opts Vibing.AdapterOpts
---@return Vibing.Response
function AgentSDK:execute(prompt, opts)
  opts = opts or {}
  local result = { content = "" }
  local done = false

  self:stream(prompt, opts, function(chunk)
    result.content = result.content .. chunk
  end, function(response)
    if response.error then
      result.error = response.error
    end
    done = true
  end)

  vim.wait(120000, function() return done end, 100)
  return result
end

---@param prompt string
---@param opts Vibing.AdapterOpts
---@param on_chunk fun(chunk: string)
---@param on_done fun(response: Vibing.Response)
function AgentSDK:stream(prompt, opts, on_chunk, on_done)
  opts = opts or {}
  local cmd = self:build_command(prompt, opts)
  local output = {}
  local error_output = {}
  local stdout_buffer = ""

  self._handle = vim.system(cmd, {
    text = true,
    stdout = function(err, data)
      if err then return end
      if not data then return end

      vim.schedule(function()
        -- Buffer and process line by line
        stdout_buffer = stdout_buffer .. data
        while true do
          local newline_pos = stdout_buffer:find("\n")
          if not newline_pos then break end

          local line = stdout_buffer:sub(1, newline_pos - 1)
          stdout_buffer = stdout_buffer:sub(newline_pos + 1)

          if line ~= "" then
            local ok, msg = pcall(vim.json.decode, line)
            if ok then
              if msg.type == "session" and msg.session_id then
                -- Store session ID for subsequent calls
                self._session_id = msg.session_id
              elseif msg.type == "chunk" and msg.text then
                table.insert(output, msg.text)
                on_chunk(msg.text)
              elseif msg.type == "error" then
                table.insert(error_output, msg.message or "Unknown error")
              end
              -- "done" type is handled by process exit
            end
          end
        end
      end)
    end,
    stderr = function(err, data)
      if data then
        table.insert(error_output, data)
      end
    end,
  }, function(obj)
    vim.schedule(function()
      self._handle = nil
      if obj.code ~= 0 or #error_output > 0 then
        on_done({
          content = table.concat(output, ""),
          error = table.concat(error_output, ""),
        })
      else
        on_done({ content = table.concat(output, "") })
      end
    end)
  end)
end

function AgentSDK:cancel()
  if self._handle then
    self._handle:kill(9)
    self._handle = nil
  end
end

---@param feature string
---@return boolean
function AgentSDK:supports(feature)
  local features = {
    streaming = true,
    tools = true,
    model_selection = false,
    context = true,
    session = true,
  }
  return features[feature] or false
end

---セッションIDを設定
---@param session_id string?
function AgentSDK:set_session_id(session_id)
  self._session_id = session_id
end

---セッションIDを取得
---@return string?
function AgentSDK:get_session_id()
  return self._session_id
end

return AgentSDK
