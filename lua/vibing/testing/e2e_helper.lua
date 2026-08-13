---@class Vibing.Testing.E2EHelper
---E2Eテスト用のヘルパー関数集
local M = {}

---E2E specを実行してよい環境かどうか
---
---`test:lua`は`PlenaryBustedDirectory tests/`なので`tests/e2e/`まで巻き込む。E2Eは子Neovimを
---起動して**実際にCLIへリクエストを投げる**ものがあり、通常のユニットテストのつもりで回すと
---黙ってトークンを使う。`test:e2e`だけが`VIBING_E2E=1`を立てるので、それ以外では各specが
---自分でスキップする。
---@return boolean
function M.should_run()
  return vim.env.VIBING_E2E == "1"
end

---別Neovimインスタンスを起動
---@param config? { headless?: boolean, init_script?: string, cwd?: string }
---@return table インスタンスハンドル { job_id: number }
function M.spawn_nvim_instance(config)
  config = config or {}

  -- --embed makes the child's stdio a msgpack-RPC channel, which is what `rpc = true` below is
  -- talking to. Without it the child starts as an ordinary editor, every rpcrequest fails, and
  -- the spec never gets past its first wait.
  local cmd = { "nvim", "--clean", "--embed" }
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

---現在のバッファ「名」が条件に一致するまで待機
---
---wait_for_buffer_contentと紛らわしいが、見るものが違う。`.md`拡張子やチャットファイル名を
---待つのはこちら。本文を探しても永久に一致しないため、全specがそこで詰まっていた。
---@param instance table インスタンスハンドル
---@param pattern string Luaパターン（バッファ名に対して）
---@param timeout number タイムアウト（ミリ秒）
---@return boolean 成功したかどうか
function M.wait_for_buffer_name(instance, pattern, timeout)
  if not instance or not instance.job_id then
    vim.notify("[E2E Helper] Invalid instance: instance or job_id is nil", vim.log.levels.ERROR)
    return false
  end

  local start_time = vim.loop.hrtime()
  local timeout_ns = timeout * 1000000
  local last_name = ""

  while (vim.loop.hrtime() - start_time) < timeout_ns do
    local ok, bufnr = pcall(vim.fn.rpcrequest, instance.job_id, "nvim_get_current_buf")
    if not ok then
      vim.notify(
        string.format("[E2E Helper] RPC failed to get buffer: %s", tostring(bufnr)),
        vim.log.levels.WARN
      )
      return false
    end

    local ok2, name = pcall(vim.fn.rpcrequest, instance.job_id, "nvim_buf_get_name", bufnr)
    if not ok2 then
      vim.notify(
        string.format("[E2E Helper] RPC failed to get buffer name: %s", tostring(name)),
        vim.log.levels.WARN
      )
      return false
    end

    last_name = name or ""
    if last_name:match(pattern) then
      return true
    end

    vim.loop.sleep(100)
  end

  vim.notify(
    string.format(
      "[E2E Helper] Timeout waiting for buffer name '%s' after %dms\nLast buffer name: %s",
      pattern,
      timeout,
      last_name
    ),
    vim.log.levels.DEBUG
  )

  return false
end

---インスタンスをクリーンアップ
---子が書いたチャットファイルの一時ディレクトリも消す（tests/e2e_init.luaが場所を伝えてくる）
---@param instance table インスタンスハンドル
function M.cleanup_instance(instance)
  if not instance or not instance.job_id then
    return
  end

  local ok, chat_dir = pcall(vim.fn.rpcrequest, instance.job_id, "nvim_get_var", "vibing_e2e_chat_dir")
  vim.fn.jobstop(instance.job_id)

  if not ok or type(chat_dir) ~= "string" or chat_dir == "" then
    return
  end

  -- This path arrived over RPC and is about to be handed to `delete(..., "rf")`, so confirm it is
  -- under the system temp dir first. Normalize both sides with vim.fs.normalize, which collapses
  -- `..`: a prefix test on raw strings (or on `fnamemodify(:p)`, which leaves `..` in place —
  -- checked, not assumed) would accept `<temp>/../../etc`.
  --
  -- The base comes from tempname()'s own layout (`<temp>/nvim.<user>/<rand>/<counter>`), a Neovim
  -- implementation detail. If that ever changes the comparison simply stops matching, so the
  -- failure mode is a leftover temp directory rather than a wrong `rf`.
  -- Trailing separator so the prefix test lands on a directory boundary: without it a base of
  -- `<temp>/nvim.foo` also matches `<temp>/nvim.foobar/...`, a different directory entirely.
  local temp_base = vim.fs.normalize(vim.fn.fnamemodify(vim.fn.tempname(), ":h:h")) .. "/"
  if vim.fs.normalize(chat_dir):find(temp_base, 1, true) == 1 then
    vim.fn.delete(vim.fn.fnamemodify(chat_dir, ":h"), "rf")
  end
end

return M
