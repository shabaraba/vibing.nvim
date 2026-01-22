---@class Vibing.RpcServer
---Neovim RPC server for MCP integration
---非同期TCPサーバーとしてMCPサーバーからのリクエストを処理
---vim.loopによる非同期I/Oでデッドロックを回避
local M = {}

local uv = vim.loop
local notify = require("vibing.core.utils.notify")
local handlers = require("vibing.infrastructure.rpc.handlers")
local registry = require("vibing.infrastructure.rpc.registry")

---@type uv_tcp_t?
local server = nil

---@type table<uv_tcp_t, boolean>
local clients = {}

---@type number?
local current_port = nil

---Handle incoming JSON-RPC request
---@param client uv_tcp_t クライアントソケット
-- Process a newline-delimited JSON-RPC request string and send a JSON-RPC response to the client.
-- Schedules handler execution on the Neovim main loop, dispatches the request to the corresponding entry in `handlers`,
-- and writes either a `{ id = req.id, result = ... }` or `{ id = req.id, error = ... }` response (followed by a newline) to the client.
-- @param client uv_tcp_t|nil TCP client handle; if `nil` or closing, no response will be written.
-- @param request string JSON-RPC request as a single-line JSON string.
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

---Start RPC server with dynamic port allocation
---Tries ports from base_port to base_port+49 until finding an available one
---@param base_port? number Base port number (default: 9876)
---@return number port Actual port number in use (0 if failed)
function M.start(base_port)
  base_port = base_port or 9876

  if server then
    notify.warn(string.format("RPC server already running on port %d", current_port))
    return current_port
  end

  local max_attempts = 50
  local successful_port = nil

  -- Cache instance list once to avoid repeated file I/O in port loop
  local registered_instances = registry.list()

  -- Try ports from base_port to base_port+49
  for i = 0, max_attempts - 1 do
    local try_port = base_port + i

    -- Skip if port is already in use by another instance (check registry)
    -- Note: TOCTOU race condition is acceptable here - bind() will fail atomically
    -- if port becomes occupied between this check and the bind() call
    if registry.is_port_in_use(try_port, registered_instances) then
      goto continue
    end

    server = uv.new_tcp()
    -- Atomically attempt to bind to the port
    -- If another process takes the port between the registry check and this call,
    -- bind() will fail and we'll try the next port
    local bind_ok, bind_err = server:bind("127.0.0.1", try_port)

    if bind_ok then
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

      if listen_ok then
        successful_port = try_port
        current_port = try_port
        break
      else
        -- Listen failed, cleanup socket before trying next port
        notify.warn(string.format("Failed to listen on port %d: %s", try_port, listen_err or "unknown"))
        if server then
          server:close()
        end
        server = nil
      end
    else
      -- Bind failed, cleanup socket before trying next port
      if server then
        server:close()
      end
      server = nil
    end

    ::continue::
  end

  if not successful_port then
    notify.error(
      string.format(
        "Failed to start RPC server: all ports (%d-%d) are in use",
        base_port,
        base_port + max_attempts - 1
      )
    )
    return 0
  end

  -- Register instance in registry
  local registry_ok = registry.register(successful_port)
  if not registry_ok then
    notify.warn("RPC server started but failed to register instance")
  end

  notify.info(string.format("RPC server started on port %d", successful_port))

  return successful_port
end

---Stop RPC server and unregister instance
function M.stop()
  -- Close all client connections
  for client, _ in pairs(clients) do
    pcall(function()
      if not client:is_closing() then
        client:close()
      end
    end)
  end
  clients = {}

  -- Close server
  if server then
    pcall(function()
      if not server:is_closing() then
        server:close()
      end
    end)
    server = nil
    current_port = nil

    -- Unregister from registry
    registry.unregister()

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
