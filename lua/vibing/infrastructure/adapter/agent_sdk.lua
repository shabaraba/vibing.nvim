---@class Vibing.Infrastructure.AgentSDKAdapter
---Claude Agent SDKアダプター
local BaseAdapter = require("vibing.infrastructure.adapter.base")

local AgentSDKAdapter = setmetatable({}, { __index = BaseAdapter })
AgentSDKAdapter.__index = AgentSDKAdapter

---新しいAgentSDKアダプターを作成
---@param config table
---@return Vibing.Infrastructure.AgentSDKAdapter
function AgentSDKAdapter:new(config)
  local instance = BaseAdapter.new(self, config)
  setmetatable(instance, AgentSDKAdapter)
  instance.name = "agent_sdk"
  instance._handles = {}
  instance._sessions = {}
  local source = debug.getinfo(1, "S").source:sub(2)
  instance._plugin_root = vim.fn.fnamemodify(source, ":h:h:h:h:h")
  math.randomseed(vim.loop.hrtime())
  return instance
end

---ラッパースクリプトのパスを取得
---@return string
function AgentSDKAdapter:get_wrapper_path()
  return self._plugin_root .. "/bin/agent-wrapper.mjs"
end

---コマンドライン引数を構築
---@param prompt string
---@param opts table
---@param session_id string?
---@return string[]
function AgentSDKAdapter:build_command(prompt, opts, session_id)
  local cmd = { "node", self:get_wrapper_path() }

  table.insert(cmd, "--cwd")
  table.insert(cmd, vim.fn.getcwd())

  local mode = opts.mode or (self.config.agent and self.config.agent.default_mode)
  if mode then
    table.insert(cmd, "--mode")
    table.insert(cmd, mode)
  end

  local model = opts.model or (self.config.agent and self.config.agent.default_model)
  if model then
    table.insert(cmd, "--model")
    table.insert(cmd, model)
  end

  for _, ctx in ipairs(opts.context or {}) do
    if ctx:match("^@file:") then
      table.insert(cmd, "--context")
      table.insert(cmd, ctx:sub(7))
    end
  end

  if session_id then
    table.insert(cmd, "--session")
    table.insert(cmd, session_id)
  end

  local allow_tools = opts.permissions_allow and vim.deepcopy(opts.permissions_allow) or {}
  table.insert(allow_tools, "mcp__vibing-nvim__*")
  if #allow_tools > 0 then
    table.insert(cmd, "--allow")
    table.insert(cmd, table.concat(allow_tools, ","))
  end

  if opts.permissions_deny and #opts.permissions_deny > 0 then
    table.insert(cmd, "--deny")
    table.insert(cmd, table.concat(opts.permissions_deny, ","))
  end

  if opts.permissions_ask and #opts.permissions_ask > 0 then
    table.insert(cmd, "--ask")
    table.insert(cmd, table.concat(opts.permissions_ask, ","))
  end

  if opts.permission_mode then
    table.insert(cmd, "--permission-mode")
    table.insert(cmd, opts.permission_mode)
  end

  local rules = self.config.permissions and self.config.permissions.rules
  if rules and #rules > 0 then
    table.insert(cmd, "--rules")
    table.insert(cmd, vim.json.encode(rules))
  end

  local prioritize_vibing_lsp = self.config.agent and self.config.agent.prioritize_vibing_lsp
  if prioritize_vibing_lsp ~= nil then
    table.insert(cmd, "--prioritize-vibing-lsp")
    table.insert(cmd, tostring(prioritize_vibing_lsp))
  end

  local mcp_enabled = self.config.mcp and self.config.mcp.enabled
  if mcp_enabled ~= nil then
    table.insert(cmd, "--mcp-enabled")
    table.insert(cmd, tostring(mcp_enabled))
  end

  table.insert(cmd, "--prompt")
  table.insert(cmd, prompt)

  return cmd
end

---@param prompt string
---@param opts table?
---@return table
function AgentSDKAdapter:execute(prompt, opts)
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
---@param opts table?
---@param on_chunk fun(chunk: string)
---@param on_done fun(response: table)
---@return string
function AgentSDKAdapter:stream(prompt, opts, on_chunk, on_done)
  opts = opts or {}
  local handle_id = tostring(vim.loop.hrtime()) .. "_" .. tostring(math.random(100000))

  local session_id = opts._session_id_explicit and opts._session_id or opts._session_id
  local cmd = self:build_command(prompt, opts, session_id)
  local output = {}
  local error_output = {}
  local stdout_buffer = ""

  self._handles[handle_id] = vim.system(cmd, {
    text = true,
    stdout = function(err, data)
      if err or not data then return end
      vim.schedule(function()
        stdout_buffer = stdout_buffer .. data
        while true do
          local newline_pos = stdout_buffer:find("\n")
          if not newline_pos then break end

          local line = stdout_buffer:sub(1, newline_pos - 1)
          stdout_buffer = stdout_buffer:sub(newline_pos + 1)

          if line ~= "" then
            local ok, msg = pcall(vim.json.decode, line)
            if ok then
              if msg.type == "status" and opts.status_manager then
                if msg.state == "thinking" then
                  opts.status_manager:set_thinking(opts.action_type or "chat")
                elseif msg.state == "tool_use" then
                  opts.status_manager:set_tool_use(msg.tool, msg.input_summary)
                elseif msg.state == "responding" then
                  opts.status_manager:set_responding()
                end
              elseif msg.type == "session" and msg.session_id then
                self._sessions[handle_id] = msg.session_id
              elseif msg.type == "tool_use" and msg.tool and msg.file_path then
                if opts.on_tool_use then
                  opts.on_tool_use(msg.tool, msg.file_path)
                end
                if opts.status_manager then
                  opts.status_manager:add_modified_file(msg.file_path)
                end
              elseif msg.type == "chunk" and msg.text then
                table.insert(output, msg.text)
                on_chunk(msg.text)
              elseif msg.type == "error" then
                table.insert(error_output, msg.message or "Unknown error")
              end
            end
          end
        end
      end)
    end,
    stderr = function(_, data)
      if data then table.insert(error_output, data) end
    end,
  }, function(obj)
    vim.schedule(function()
      self._handles[handle_id] = nil
      if obj.code ~= 0 or #error_output > 0 then
        on_done({ content = table.concat(output, ""), error = table.concat(error_output, ""), _handle_id = handle_id })
      else
        on_done({ content = table.concat(output, ""), _handle_id = handle_id })
      end
    end)
  end)

  return handle_id
end

function AgentSDKAdapter:cancel(handle_id)
  if handle_id then
    local handle = self._handles[handle_id]
    if handle then
      handle:kill(9)
      self._handles[handle_id] = nil
    end
  else
    for id, handle in pairs(self._handles) do
      handle:kill(9)
      self._handles[id] = nil
    end
  end
end

function AgentSDKAdapter:supports(feature)
  local features = { streaming = true, tools = true, model_selection = false, context = true, session = true }
  return features[feature] or false
end

function AgentSDKAdapter:set_session_id(session_id, handle_id)
  self._sessions[handle_id or "__default__"] = session_id
end

function AgentSDKAdapter:get_session_id(handle_id)
  return self._sessions[handle_id or "__default__"]
end

function AgentSDKAdapter:cleanup_session(handle_id)
  if handle_id then self._sessions[handle_id] = nil end
end

function AgentSDKAdapter:cleanup_stale_sessions()
  for handle_id in pairs(self._sessions) do
    if handle_id ~= "__default__" and not self._handles[handle_id] then
      self._sessions[handle_id] = nil
    end
  end
end

return AgentSDKAdapter
