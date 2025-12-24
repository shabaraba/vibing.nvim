---@class Vibing.RpcServer
---Neovim RPC server for MCP integration
---非同期TCPサーバーとしてMCPサーバーからのリクエストを処理
---vim.loopによる非同期I/Oでデッドロックを回避
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

---Handle incoming JSON-RPC request
---@param client uv_tcp_t クライアントソケット
---@param request string JSON-RPC リクエスト文字列
local function handle_request(client, request)
  local ok, req = pcall(vim.json.decode, request)
  if not ok then
    local error_response = vim.json.encode({ error = "Invalid JSON" })
    if client and not client:is_closing() then
      client:write(error_response .. "\n")
    end
    return
  end

  -- vim.schedule でメインループに戻してから実行
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
      response = vim.json.encode({
        id = req.id,
        result = res,
      })
    else
      response = vim.json.encode({
        id = req.id,
        error = tostring(res),
      })
    end

    -- 非同期でレスポンス送信
    if client and not client:is_closing() then
      client:write(response .. "\n")
    end
  end)
end

---Start RPC server
---@param port? number ポート番号（デフォルト: 9876）
---@return number port 実際に使用されているポート番号
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

        -- 改行区切りで複数リクエスト処理
        while true do
          local newline_pos = buffer:find("\n")
          if not newline_pos then
            break
          end

          local line = buffer:sub(1, newline_pos - 1)
          buffer = buffer:sub(newline_pos + 1)

          if #line > 0 then
            handle_request(client, line)
          end
        end
      else
        -- EOF
        clients[client] = nil
        client:close()
      end
    end)
  end)

  if not listen_ok then
    notify.error(string.format("Failed to listen on RPC server: %s", listen_err))
    server:close()
    server = nil
    return 0
  end

  current_port = port
  notify.info(string.format("RPC server started on port %d", port))

  return port
end

---Stop RPC server
function M.stop()
  -- Close all client connections
  for client, _ in pairs(clients) do
    if not client:is_closing() then
      client:close()
    end
  end
  clients = {}

  -- Close server
  if server then
    server:close()
    server = nil
    current_port = nil
    notify.info("RPC server stopped")
  end
end

---Get current port number
---@return number? port ポート番号（サーバーが起動していない場合はnil）
function M.get_port()
  return current_port
end

---Check if server is running
---@return boolean running サーバーが起動中かどうか
function M.is_running()
  return server ~= nil
end

return M
