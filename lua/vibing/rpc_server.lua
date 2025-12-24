---@class Vibing.RpcServer
---Neovim RPC server for MCP integration
---非同期TCPサーバーとしてMCPサーバーからのリクエストを処理
---vim.loopによる非同期I/Oでデッドロックを回避
local M = {}

local uv = vim.loop
local notify = require("vibing.utils.notify")

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

      if method == "buf_get_lines" then
        local bufnr = req.params and req.params.bufnr or 0
        return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

      elseif method == "buf_set_lines" then
        local bufnr = req.params and req.params.bufnr or 0
        local lines = req.params and req.params.lines
        if type(lines) == "string" then
          lines = vim.split(lines, "\n")
        end
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
        return { success = true }

      elseif method == "get_current_file" then
        local bufnr = vim.api.nvim_get_current_buf()
        return {
          bufnr = bufnr,
          filename = vim.fn.expand("%:p"),
          filetype = vim.bo.filetype,
          modified = vim.bo[bufnr].modified,
        }

      elseif method == "execute" then
        local cmd = req.params and req.params.command
        if not cmd then
          error("Missing command parameter")
        end
        vim.cmd(cmd)
        return { success = true }

      elseif method == "get_visual_selection" then
        local start_pos = vim.fn.getpos("'<")
        local end_pos = vim.fn.getpos("'>")
        local lines = vim.fn.getline(start_pos[2], end_pos[2])
        return {
          lines = lines,
          start = start_pos,
          ["end"] = end_pos,
        }

      elseif method == "list_buffers" then
        local bufs = {}
        for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
          if vim.api.nvim_buf_is_loaded(bufnr) then
            table.insert(bufs, {
              bufnr = bufnr,
              name = vim.api.nvim_buf_get_name(bufnr),
              modified = vim.bo[bufnr].modified,
              filetype = vim.bo[bufnr].filetype,
            })
          end
        end
        return bufs

      elseif method == "get_cursor_position" then
        local pos = vim.api.nvim_win_get_cursor(0)
        return {
          line = pos[1],
          col = pos[2],
        }

      elseif method == "set_cursor_position" then
        local line = req.params and req.params.line
        local col = req.params and req.params.col or 0
        if not line then
          error("Missing line parameter")
        end
        vim.api.nvim_win_set_cursor(0, { line, col })
        return { success = true }

      elseif method == "list_windows" then
        local wins = {}
        local current_win = vim.api.nvim_get_current_win()
        for _, info in ipairs(vim.fn.getwininfo()) do
          local winnr = info.winid
          local bufnr = info.bufnr
          local config = vim.api.nvim_win_get_config(winnr)
          table.insert(wins, {
            winnr = winnr,
            bufnr = bufnr,
            buffer_name = vim.api.nvim_buf_get_name(bufnr),
            filetype = vim.bo[bufnr].filetype,
            width = info.width,
            height = info.height,
            row = config.row or 0,
            col = config.col or 0,
            relative = config.relative or "",
            is_current = winnr == current_win,
            is_floating = config.relative ~= "",
          })
        end
        return wins

      elseif method == "get_window_info" then
        local winnr = req.params and req.params.winnr or 0
        if winnr ~= 0 and not vim.api.nvim_win_is_valid(winnr) then
          error("Invalid window number: " .. tostring(winnr))
        end
        local bufnr = vim.api.nvim_win_get_buf(winnr)
        local config = vim.api.nvim_win_get_config(winnr)
        local cursor = vim.api.nvim_win_get_cursor(winnr)
        return {
          winnr = winnr,
          bufnr = bufnr,
          buffer_name = vim.api.nvim_buf_get_name(bufnr),
          filetype = vim.bo[bufnr].filetype,
          width = vim.api.nvim_win_get_width(winnr),
          height = vim.api.nvim_win_get_height(winnr),
          row = config.row or 0,
          col = config.col or 0,
          relative = config.relative or "",
          is_current = winnr == vim.api.nvim_get_current_win(),
          is_floating = config.relative ~= "",
          cursor = { line = cursor[1], col = cursor[2] },
        }

      elseif method == "get_window_view" then
        local winnr = req.params and req.params.winnr or 0
        if winnr ~= 0 and not vim.api.nvim_win_is_valid(winnr) then
          error("Invalid window number: " .. tostring(winnr))
        end
        local bufnr = vim.api.nvim_win_get_buf(winnr)
        local cursor = vim.api.nvim_win_get_cursor(winnr)
        local wininfo = vim.fn.getwininfo(winnr)[1]
        return {
          winnr = winnr,
          bufnr = bufnr,
          topline = vim.fn.line("w0", winnr),
          botline = vim.fn.line("w$", winnr),
          width = vim.api.nvim_win_get_width(winnr),
          height = vim.api.nvim_win_get_height(winnr),
          cursor = { line = cursor[1], col = cursor[2] },
          leftcol = wininfo and wininfo.leftcol or 0,
        }

      elseif method == "list_tabpages" then
        local tabs = {}
        local current_tab = vim.api.nvim_get_current_tabpage()
        for _, tabnr in ipairs(vim.api.nvim_list_tabpages()) do
          local wins = vim.api.nvim_tabpage_list_wins(tabnr)
          local win_info = {}
          for _, winnr in ipairs(wins) do
            local bufnr = vim.api.nvim_win_get_buf(winnr)
            table.insert(win_info, {
              winnr = winnr,
              bufnr = bufnr,
              buffer_name = vim.api.nvim_buf_get_name(bufnr),
            })
          end
          table.insert(tabs, {
            tabnr = tabnr,
            window_count = #wins,
            windows = win_info,
            is_current = tabnr == current_tab,
          })
        end
        return tabs

      elseif method == "set_window_width" then
        local winnr = req.params and req.params.winnr or 0
        local width = req.params and req.params.width
        if not width then
          error("Missing width parameter")
        end
        if winnr ~= 0 and not vim.api.nvim_win_is_valid(winnr) then
          error("Invalid window number: " .. tostring(winnr))
        end
        vim.api.nvim_win_set_width(winnr, width)
        return { success = true }

      elseif method == "set_window_height" then
        local winnr = req.params and req.params.winnr or 0
        local height = req.params and req.params.height
        if not height then
          error("Missing height parameter")
        end
        if winnr ~= 0 and not vim.api.nvim_win_is_valid(winnr) then
          error("Invalid window number: " .. tostring(winnr))
        end
        vim.api.nvim_win_set_height(winnr, height)
        return { success = true }

      elseif method == "focus_window" then
        local winnr = req.params and req.params.winnr
        if not winnr then
          error("Missing winnr parameter")
        end
        if not vim.api.nvim_win_is_valid(winnr) then
          error("Invalid window number: " .. tostring(winnr))
        end
        vim.api.nvim_set_current_win(winnr)
        return { success = true }

      elseif method == "win_set_buf" then
        local winnr = req.params and req.params.winnr
        local bufnr = req.params and req.params.bufnr
        if not winnr or not bufnr then
          error("Missing winnr or bufnr parameter")
        end
        if not vim.api.nvim_win_is_valid(winnr) then
          error("Invalid window number: " .. tostring(winnr))
        end
        if not vim.api.nvim_buf_is_valid(bufnr) then
          error("Invalid buffer number: " .. tostring(bufnr))
        end
        vim.api.nvim_win_set_buf(winnr, bufnr)
        return { success = true }

      elseif method == "win_open_file" then
        local winnr = req.params and req.params.winnr
        local filepath = req.params and req.params.filepath
        if not winnr or not filepath then
          error("Missing winnr or filepath parameter")
        end
        -- Validate filepath
        if filepath == "" or filepath:match("^%s*$") then
          error("Invalid filepath: empty or whitespace-only")
        end
        if filepath:match("\0") then
          error("Invalid filepath: contains null character")
        end
        if not vim.api.nvim_win_is_valid(winnr) then
          error("Invalid window number: " .. tostring(winnr))
        end
        local current = vim.api.nvim_get_current_win()
        vim.api.nvim_set_current_win(winnr)
        vim.cmd("edit " .. vim.fn.fnameescape(filepath))
        local opened_bufnr = vim.api.nvim_get_current_buf()  -- Capture before restoring focus
        if winnr ~= current then
          vim.api.nvim_set_current_win(current)
        end
        return {
          success = true,
          bufnr = opened_bufnr
        }

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
