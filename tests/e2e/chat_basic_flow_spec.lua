-- E2E Tests for vibing.nvim chat basic flow
local helper = require("vibing.testing.e2e_helper")

-- tests/e2e is swept by `test:lua` too, and some of these specs send a real request to the CLI.
-- Only `test:e2e` sets VIBING_E2E=1; everything else skips rather than quietly spending tokens.
if not helper.should_run() then
  return
end

-- Timeout constants
-- プロンプトにしか現れない語。モデルが本当に答えたときにしかバッファに現れないので、
-- 「応答が来た」と「ターンの見出しが書かれた」を取り違えずに済む
local MARKER = "VBGXKQ"

local TIMEOUTS = {
  CHAT_CREATION = 2000, -- Time for chat buffer creation and rendering
  BUFFER_READY = 5000, -- Time for buffer to be ready with .md extension
  FRONTMATTER = 2000, -- Time for frontmatter to be populated
  CURSOR_MOVE = 100, -- Time for cursor movement to complete
  ASSISTANT_RESPONSE = 30000, -- Maximum wait time for Assistant response (30s)
}

describe("E2E: Chat basic flow", function()
  local nvim_instance

  before_each(function()
    -- 別Neovimインスタンスを起動（vibing.nvimロード済み）
    nvim_instance = helper.spawn_nvim_instance({
      headless = true,
      init_script = "tests/e2e_init.lua",
    })
    vim.wait(800)
    -- minimal_init only puts the plugin on the runtimepath; the :Vibing* commands these specs
    -- drive are registered by setup(), so the child has to be set up explicitly.
    vim.fn.rpcrequest(nvim_instance.job_id, "nvim_exec_lua", "require('vibing').setup({})", {})
  end)

  after_each(function()
    helper.cleanup_instance(nvim_instance)
  end)

  it("should create chat buffer and display initial state", function()
    -- チャット作成コマンド送信
    helper.send_keys(nvim_instance, ":VibingChat<CR>")

    -- バッファ作成待機
    vim.wait(TIMEOUTS.CHAT_CREATION)

    -- バッファ名確認（.mdファイルが作成される）
    local ok = helper.wait_for_buffer_name(nvim_instance, "%.md$", TIMEOUTS.BUFFER_READY)
    assert.is_true(ok, "Chat buffer should be created with .md extension")

    -- フロントマター確認
    ok = helper.wait_for_buffer_content(nvim_instance, "created_at:", TIMEOUTS.FRONTMATTER)
    assert.is_true(ok, "Frontmatter should contain created_at field")
  end)

  it("should send message and receive response", function()
    -- チャット作成
    helper.send_keys(nvim_instance, ":VibingChat<CR>")
    vim.wait(TIMEOUTS.CHAT_CREATION)

    -- バッファ作成確認
    local ok = helper.wait_for_buffer_name(nvim_instance, "%.md$", TIMEOUTS.BUFFER_READY)
    assert.is_true(ok, "Chat buffer should be created")

    -- メッセージ送信（簡単なプロンプト）
    -- Unsent User headerまでジャンプ
    helper.send_keys(nvim_instance, "G")
    vim.wait(TIMEOUTS.CURSOR_MOVE)

    -- Insert modeでメッセージ入力
    helper.send_keys(nvim_instance, "i")
    helper.send_keys(nvim_instance, "Reply with ONLY the word " .. MARKER .. ". Do not use any tools.")
    helper.send_keys(nvim_instance, "<Esc>")

    -- <CR>でメッセージ送信
    helper.send_keys(nvim_instance, "<CR>")

    -- **モデルが実際に答えたこと**を待つ。`## .* Assistant` の見出しだけを待っていたころは、
    -- CLIが即座に失敗したターンでも見出しは書かれるのでこのspecは緑のままだった
    -- （root環境で `--dangerously-skip-permissions` が拒否されるケースで実際に起きた）。
    -- マーカーはプロンプトからしか出てこない語にしてある
    local reason
    ok, reason = helper.wait_for_response(nvim_instance, MARKER, TIMEOUTS.ASSISTANT_RESPONSE)
    assert.is_true(ok, reason or "Assistant response should appear within timeout")
  end)
end)
