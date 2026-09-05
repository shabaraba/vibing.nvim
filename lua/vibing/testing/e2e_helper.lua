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

---子Neovim（とそれが起動するCLI）に渡す環境変数
---
---`tests/e2e_init.lua` は `permissions.mode = "bypassPermissions"` を決め打ちしており、
---それ自体は必要（同ファイルのコメント参照: acceptEdits ではCLIが vibing-nvim の MCP ツールを
---拒否し、`--allowedTools` でも解けない）。ところがそのモードは CLI 内部で
---`--dangerously-skip-permissions` になり、**root で走っているとCLIが起動を拒否する**：
---
---  --dangerously-skip-permissions cannot be used with root/sudo privileges for security reasons
---
---コンテナ（CI、Claude Code on the web、devcontainer）は uid 0 で走るのが普通なので、そこでは
---実ターンに依存するE2Eが1本も通らない。`IS_SANDBOX=1` はCLIが用意しているそのための逃げ道で、
---root チェックだけを外す。
---
---**uid 0 のときにしか渡さない。** 無条件に立てると、開発者が自分のマシンで
---`npm run test:e2e` を叩いたときにも安全確認を1つ黙って外すことになる。そこでは root で
---走っていないので、そもそも外すものが無い
---@param chat_dir string
---@return table<string, string>
local function child_env(chat_dir)
  local env = { VIBING_E2E_CHAT_DIR = chat_dir }
  if vim.loop.getuid and vim.loop.getuid() == 0 then
    env.IS_SANDBOX = "1"
  end
  return env
end

---別Neovimインスタンスを起動
---@param config? { headless?: boolean, init_script?: string, cwd?: string }
---@return table インスタンスハンドル { job_id: number, chat_dir: string }
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

  -- The parent picks where the child writes its chats, rather than the child picking and the
  -- parent asking for it afterwards. Asking would mean an rpcrequest during cleanup, and
  -- rpcrequest has no timeout: a child wedged by a failing test would hang after_each, and with
  -- it the whole suite. Owning the path here means cleanup only ever calls jobstop and delete.
  -- Only the path is decided here; tests/e2e_init.lua does the mkdir in the child. Creating it
  -- before jobstart would leak the directory on the `error()` below, since the caller never gets
  -- an instance to hand to cleanup_instance.
  local chat_dir = vim.fn.tempname() .. "/chat"

  local instance = {
    chat_dir = chat_dir,
    job_id = vim.fn.jobstart(cmd, {
      cwd = config.cwd or vim.fn.getcwd(),
      rpc = true,
      env = child_env(chat_dir),
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

---現在のバッファについて、`read` が返す文字列がパターンに一致するまでポーリングする。
---
---wait_for_buffer_content と wait_for_buffer_name はこの1点しか違わない（本文か、名前か）。
---@param instance table インスタンスハンドル
---@param pattern string Luaパターン
---@param timeout number タイムアウト（ミリ秒）
---@param label string タイムアウトメッセージでの呼び名
---@param read fun(job_id: number, bufnr: number): boolean, string 対象を取り出す
---@return boolean 成功したかどうか
local function wait_for(instance, pattern, timeout, label, read)
  if not instance or not instance.job_id then
    vim.notify("[E2E Helper] Invalid instance: instance or job_id is nil", vim.log.levels.ERROR)
    return false
  end

  local start_time = vim.loop.hrtime()
  local timeout_ns = timeout * 1000000
  local last_seen = ""

  while (vim.loop.hrtime() - start_time) < timeout_ns do
    local ok, bufnr = pcall(vim.fn.rpcrequest, instance.job_id, "nvim_get_current_buf")
    if not ok then
      vim.notify(
        string.format("[E2E Helper] RPC failed to get buffer: %s", tostring(bufnr)),
        vim.log.levels.WARN
      )
      return false
    end

    local ok2, value = read(instance.job_id, bufnr)
    if not ok2 then
      vim.notify(
        string.format("[E2E Helper] RPC failed to get buffer %s: %s", label, tostring(value)),
        vim.log.levels.WARN
      )
      return false
    end

    last_seen = value or ""
    if last_seen:match(pattern) then
      return true
    end

    vim.loop.sleep(100)
  end

  vim.notify(
    string.format(
      "[E2E Helper] Timeout waiting for buffer %s '%s' after %dms\nLast buffer %s:\n%s",
      label,
      pattern,
      timeout,
      label,
      last_seen:sub(1, 500) -- truncated: a whole chat buffer is too much for one notification
    ),
    vim.log.levels.DEBUG
  )

  return false
end

---現在のバッファの本文を1回読む。`wait_for` の `read` と同じ形（job_id, bufnr）
---@param job_id number
---@param bufnr number
---@return boolean ok
---@return string text_or_error
local function read_content(job_id, bufnr)
  local ok, lines = pcall(vim.fn.rpcrequest, job_id, "nvim_buf_get_lines", bufnr, 0, -1, false)
  return ok, ok and table.concat(lines, "\n") or lines
end

---バッファ「本文」が条件に一致するまで待機
---@param instance table インスタンスハンドル
---@param pattern string パターン（Luaパターン）
---@param timeout number タイムアウト（ミリ秒）
---@return boolean 成功したかどうか
function M.wait_for_buffer_content(instance, pattern, timeout)
  return wait_for(instance, pattern, timeout, "content", read_content)
end

---失敗したターンがチャットに書く行（`application/chat/send_message.lua`）。
---
---パターンをここに1つだけ置いてあるのは、これが「ターンが動いたか」を判定する唯一の手掛かり
---だから。specごとに書くと、文言が変わった日にすべてのspecが黙って「エラーなし」に倒れる
local TURN_ERROR_PATTERN = "%*%*Error:%*%* [^\n]*"

---Assistantセクションの見出し（タイムスタンプ付き・レガシーの両方）
local ASSISTANT_HEADER_PATTERN = "\n## [^\n]*Assistant[^\n]*"

---チャット本文を条件が満たされるまでポーリングする。**ターンがエラーで書いた行を見つけたら
---そこで打ち切る。**
---
---打ち切りが要点。待つ対象を「モデルが実際に出したもの」にすると、ターンが失敗したときに
---「モデルが期待した出力を返さなかった」という**嘘の診断**でタイムアウトまで待つことになる
---（`plugin_dir_spec` が実際に、CLIが起動を拒否しただけの失敗を `--plugin-dir` のせいだと
---60秒かけて報告していた）。
---@param instance table インスタンスハンドル
---@param timeout number タイムアウト（ミリ秒）
---@param done fun(text: string): boolean 本文を見て満たされたか
---@param what string タイムアウトメッセージでの呼び名
---@return boolean ok
---@return string? reason 失敗した理由（成功時は nil）
local function poll_chat(instance, timeout, done, what)
  if not instance or not instance.job_id then
    return false, "Invalid instance: instance or job_id is nil"
  end

  local deadline = vim.loop.hrtime() + timeout * 1000000
  local last_seen = ""

  while vim.loop.hrtime() < deadline do
    local ok, bufnr = pcall(vim.fn.rpcrequest, instance.job_id, "nvim_get_current_buf")
    if not ok then
      return false, string.format("RPC failed to get buffer: %s", tostring(bufnr))
    end

    local ok2, text = read_content(instance.job_id, bufnr)
    if not ok2 then
      return false, string.format("RPC failed to read buffer: %s", tostring(text))
    end

    last_seen = text or ""
    -- 条件の判定はエラー判定の**前**。エラー行と期待した出力が同じ本文に並ぶことは原理的に
    -- ありうるので、逆にすると成功を失敗として報告しうる
    if done(last_seen) then
      return true
    end

    local turn_error = last_seen:match(TURN_ERROR_PATTERN)
    if turn_error then
      return false, string.format("The turn failed before producing %s: %s", what, turn_error)
    end

    vim.loop.sleep(100)
  end

  return false,
    string.format(
      "Timed out after %dms waiting for %s. Last 500 chars of the chat:\n%s",
      timeout,
      what,
      last_seen:sub(-500)
    )
end

---最後の `## ... Assistant` 見出しより後ろ（＝直近の応答本文）
---@param text string
---@return string? nil なら応答がまだ1つも無い
local function assistant_tail(text)
  local last_end, from = nil, 1
  while true do
    local s, e = text:find(ASSISTANT_HEADER_PATTERN, from)
    if not s then
      break
    end
    last_end, from = e, e + 1
  end
  return last_end and text:sub(last_end + 1) or nil
end

---@param text string
---@return number
local function count_assistant_headers(text)
  local count, from = 0, 1
  while true do
    local s, e = text:find(ASSISTANT_HEADER_PATTERN, from)
    if not s then
      return count
    end
    count, from = count + 1, e + 1
  end
end

---**モデルが実際に出した文字列**を待つ。ターンがエラーで死んだら理由ごと打ち切る。
---
---照合するのは最後の `## ... Assistant` 見出しより後ろだけで、バッファ全体ではない。
---全体を見ると、プロンプトに書いた語がそのまま `## User` セクションで一致してしまい、
---ターンが1バイトも返していなくても spec が緑になる（マーカー語を頼む書き方をした瞬間に
---そうなる）。
---
---逆に、チャットUIがユーザーセクションに描くもの（承認プロンプト、質問の選択肢）を待つのは
---`wait_for_response` のほう
---@param instance table インスタンスハンドル
---@param pattern string 応答本文に期待するLuaパターン
---@param timeout number タイムアウト（ミリ秒）
---@return boolean ok
---@return string? reason
function M.wait_for_assistant_text(instance, pattern, timeout)
  return poll_chat(instance, timeout, function(text)
    local tail = assistant_tail(text)
    return tail ~= nil and tail:match(pattern) ~= nil
  end, string.format("assistant output matching '%s'", pattern))
end

---ターンが走った結果としてバッファに現れるものを待つ。ターンがエラーで死んだら打ち切る。
---
---`wait_for_buffer_content` との違いは打ち切りだけ。CLIが失敗したターンでも
---`## ... Assistant` の見出しは書かれるので、ターンに依存する待ちは全部こちらを通す
---@param instance table インスタンスハンドル
---@param pattern string Luaパターン（バッファ全体に対して）
---@param timeout number タイムアウト（ミリ秒）
---@return boolean ok
---@return string? reason
function M.wait_for_response(instance, pattern, timeout)
  return poll_chat(instance, timeout, function(text)
    return text:match(pattern) ~= nil
  end, string.format("'%s'", pattern))
end

---Assistantの応答が `count` 本になるまで待つ。
---
---「ターンが1本走って、しかも失敗しなかった」を言うのに、モデルが特定の語を返してくれることに
---賭けずに済む形。`## .* Assistant` を `wait_for_buffer_content` で待つのとは違い、
---エラーで死んだターンはここで打ち切られる
---@param instance table インスタンスハンドル
---@param count number 期待する応答の本数
---@param timeout number タイムアウト（ミリ秒）
---@return boolean ok
---@return string? reason
function M.wait_for_assistant_turns(instance, count, timeout)
  return poll_chat(instance, timeout, function(text)
    return count_assistant_headers(text) >= count
  end, string.format("%d assistant turn(s)", count))
end

---バッファ「名」が条件に一致するまで待機
---
---wait_for_buffer_contentと紛らわしいが、見るものが違う。`.md`拡張子やチャットファイル名を
---待つのはこちら。本文を探しても永久に一致しないため、全specがそこで詰まっていた。
---@param instance table インスタンスハンドル
---@param pattern string Luaパターン（バッファ名に対して）
---@param timeout number タイムアウト（ミリ秒）
---@return boolean 成功したかどうか
function M.wait_for_buffer_name(instance, pattern, timeout)
  return wait_for(instance, pattern, timeout, "name", function(job_id, bufnr)
    return pcall(vim.fn.rpcrequest, job_id, "nvim_buf_get_name", bufnr)
  end)
end

---インスタンスをクリーンアップ
---子が書いたチャットファイルの一時ディレクトリも消す（spawn時にこちらが決めた場所）
---@param instance table インスタンスハンドル
function M.cleanup_instance(instance)
  if not instance or not instance.job_id then
    return
  end

  -- jobstop first, and no RPC anywhere in here: a child wedged by a failing test must not be able
  -- to hang the suite's cleanup. `chat_dir` is the path this process created in
  -- spawn_nvim_instance, so it needs no validation before deletion — nothing the child said is
  -- involved. Delete the tempname() directory itself, one level above the `chat` subdir; if the
  -- child never got far enough to create it, this is a no-op.
  vim.fn.jobstop(instance.job_id)

  if type(instance.chat_dir) == "string" and instance.chat_dir ~= "" then
    vim.fn.delete(vim.fn.fnamemodify(instance.chat_dir, ":h"), "rf")
  end
end

return M
