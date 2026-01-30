---@class Vibing.Testing.E2EHelper
---E2Eテスト用のヘルパー関数集
local M = {}

---別Neovimインスタンスを起動
---@param config? { headless?: boolean, init_script?: string, cwd?: string }
---@return table インスタンスハンドル { job_id: number }
function M.spawn_nvim_instance(config)
  config = config or {}

  local cmd = { "nvim", "--clean" }
  if config.headless then
    table.insert(cmd, "--headless")
  end
  if config.init_script then
    table.insert(cmd, "-u")
    table.insert(cmd, config.init_script)
  end

  local instance = {
    job_id = vim.fn.jobstart(cmd, {
      cwd = config.cwd or vim.fn.getcwd(),
      rpc = true,
      on_exit = function(_, code)
        if code ~= 0 then
          vim.notify("[E2E] Nvim instance exited with code: " .. code, vim.log.levels.WARN)
        end
      end,
    }),
  }

  if instance.job_id <= 0 then
    error("Failed to start Neovim instance")
  end

  return instance
end

---キー入力を送信
---@param instance table インスタンスハンドル
---@param keys string キーシーケンス
---@return boolean 成功したかどうか
function M.send_keys(instance, keys)
  if not instance or not instance.job_id then
    vim.notify("[E2E Helper] Invalid instance in send_keys", vim.log.levels.ERROR)
    return false
  end

  local ok, err = pcall(vim.fn.rpcrequest, instance.job_id, "nvim_input", keys)
  if not ok then
    vim.notify(
      string.format("[E2E Helper] Failed to send keys '%s': %s", keys, tostring(err)),
      vim.log.levels.WARN
    )
    return false
  end
  return true
end

---バッファ内容が条件に一致するまで待機
---@param instance table インスタンスハンドル
---@param pattern string パターン（文字列一致またはLuaパターン）
---@param timeout number タイムアウト（ミリ秒）
---@return boolean 成功したかどうか
function M.wait_for_buffer_content(instance, pattern, timeout)
  if not instance or not instance.job_id then
    vim.notify(
      "[E2E Helper] Invalid instance: instance or job_id is nil",
      vim.log.levels.ERROR
    )
    return false
  end

  local start_time = vim.loop.hrtime()
  local timeout_ns = timeout * 1000000
  local last_content = ""

  while (vim.loop.hrtime() - start_time) < timeout_ns do
    local ok, bufnr = pcall(vim.fn.rpcrequest, instance.job_id, "nvim_get_current_buf")
    if not ok then
      vim.notify(
        string.format(
          "[E2E Helper] RPC failed to get buffer: %s",
          tostring(bufnr)
        ),
        vim.log.levels.WARN
      )
      return false
    end

    local ok2, lines = pcall(vim.fn.rpcrequest, instance.job_id, "nvim_buf_get_lines", bufnr, 0, -1, false)
    if not ok2 then
      vim.notify(
        string.format(
          "[E2E Helper] RPC failed to get buffer lines: %s",
          tostring(lines)
        ),
        vim.log.levels.WARN
      )
      return false
    end

    local content = table.concat(lines, "\n")
    last_content = content

    if content:match(pattern) then
      return true
    end

    vim.loop.sleep(100)
  end

  -- Timeout occurred - provide debug information
  vim.notify(
    string.format(
      "[E2E Helper] Timeout waiting for pattern '%s' after %dms\nLast buffer content:\n%s",
      pattern,
      timeout,
      last_content:sub(1, 500) -- First 500 chars to avoid too long message
    ),
    vim.log.levels.DEBUG
  )

  return false
end

---インスタンスをクリーンアップ
---@param instance table インスタンスハンドル
function M.cleanup_instance(instance)
  if instance and instance.job_id then
    vim.fn.jobstop(instance.job_id)
  end
end

return M
