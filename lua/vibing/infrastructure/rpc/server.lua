---@class Vibing.Infrastructure.RpcServer
---MCP統合用のNeovim RPCサーバー
local M = {}

local uv = vim.loop
local notify = require("vibing.utils.notify")
local handlers = require("vibing.rpc_server.handlers")

---@type uv_tcp_t?
local server = nil

---@type table<uv_tcp_t, boolean>
local clients = {}

---@type number?
local current_port = nil

---リクエストを処理
---@param client uv_tcp_t
---@param request string
local function handle_request(client, request)
  local ok, req = pcall(vim.json.decode, request)
  if not ok then
    if client and not client:is_closing() then
      client:write(vim.json.encode({ error = "Invalid JSON" }) .. "\n")
    end
    return
  end

  vim.schedule(function()
    local success, res = pcall(function()
      local method = req.method
      local handler = handlers[method]
      if handler then
        return handler(req.params)
      else
        error("Unknown method: " .. tostring(method))
      end
    end)

    local response
    if success then
      response = vim.json.encode({ id = req.id, result = res })
    else
      response = vim.json.encode({ id = req.id, error = tostring(res) })
    end

    if client and not client:is_closing() then
      client:write(response .. "\n")
    end
  end)
end

---RPCサーバーを開始
---@param port number?
---@return number
function M.start(port)
  port = port or 9876

  if server then
    notify.warn(string.format("RPC server already running on port %d", current_port))
    return current_port
  end

  server = uv.new_tcp()
  local bind_ok, bind_err = server:bind("127.0.0.1", port)

  if not bind_ok then
    notify.error(string.format("Failed to bind RPC server: %s", bind_err))
    server:close()
    server = nil
    return 0
  end

  local listen_ok, listen_err = server:listen(128, function(err)
    if err then
      vim.schedule(function()
        notify.error(string.format("RPC server error: %s", err))
      end)
      return
    end

    local client = uv.new_tcp()
    server:accept(client)
    clients[client] = true

    local buffer = ""
    client:read_start(function(read_err, chunk)
      if read_err then
        clients[client] = nil
        client:close()
        return
      end

      if chunk then
        buffer = buffer .. chunk
        while true do
          local newline_pos = buffer:find("\n")
          if not newline_pos then break end

          local line = buffer:sub(1, newline_pos - 1)
          buffer = buffer:sub(newline_pos + 1)

          if #line > 0 then
            handle_request(client, line)
          end
        end
      else
        clients[client] = nil
        client:close()
      end
    end)
  end)

  if not listen_ok then
    notify.error(string.format("Failed to listen: %s", listen_err))
    server:close()
    server = nil
    return 0
  end

  current_port = port
  notify.info(string.format("RPC server started on port %d", port))
  return port
end

---RPCサーバーを停止
function M.stop()
  for client in pairs(clients) do
    if not client:is_closing() then
      client:close()
    end
  end
  clients = {}

  if server then
    server:close()
    server = nil
    current_port = nil
    notify.info("RPC server stopped")
  end
end

---現在のポート番号を取得
---@return number?
function M.get_port()
  return current_port
end

---サーバーが稼働中か確認
---@return boolean
function M.is_running()
  return server ~= nil
end

return M
