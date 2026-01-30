-- E2E Tests for vibing.nvim chat basic flow
local helper = require("vibing.testing.e2e_helper")

-- Timeout constants
local TIMEOUTS = {
  CHAT_CREATION = 2000, -- Time for chat buffer creation and rendering
  BUFFER_READY = 5000, -- Time for buffer to be ready with .vibing extension
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
      init_script = "tests/minimal_init.lua",
    })
  end)

  after_each(function()
    helper.cleanup_instance(nvim_instance)
  end)

  it("should create chat buffer and display initial state", function()
    -- チャット作成コマンド送信
    helper.send_keys(nvim_instance, ":VibingChat<CR>")

    -- バッファ作成待機
    vim.wait(TIMEOUTS.CHAT_CREATION)

    -- バッファ名確認（.vibingファイルが作成される）
    local ok = helper.wait_for_buffer_content(nvim_instance, "%.vibing", TIMEOUTS.BUFFER_READY)
    assert.is_true(ok, "Chat buffer should be created with .vibing extension")

    -- フロントマター確認
    ok = helper.wait_for_buffer_content(nvim_instance, "created_at:", TIMEOUTS.FRONTMATTER)
    assert.is_true(ok, "Frontmatter should contain created_at field")
  end)

  it("should send message and receive response", function()
    -- チャット作成
    helper.send_keys(nvim_instance, ":VibingChat<CR>")
    vim.wait(TIMEOUTS.CHAT_CREATION)

    -- バッファ作成確認
    local ok = helper.wait_for_buffer_content(nvim_instance, "%.vibing", TIMEOUTS.BUFFER_READY)
    assert.is_true(ok, "Chat buffer should be created")

    -- メッセージ送信（簡単なプロンプト）
    -- Unsent User headerまでジャンプ
    helper.send_keys(nvim_instance, "G")
    vim.wait(TIMEOUTS.CURSOR_MOVE)

    -- Insert modeでメッセージ入力
    helper.send_keys(nvim_instance, 'i')
    helper.send_keys(nvim_instance, 'Say "test"')
    helper.send_keys(nvim_instance, "<Esc>")

    -- <CR>でメッセージ送信
    helper.send_keys(nvim_instance, "<CR>")

    -- Assistantレスポンス待機
    ok = helper.wait_for_buffer_content(nvim_instance, "## .* Assistant", TIMEOUTS.ASSISTANT_RESPONSE)
    assert.is_true(ok, "Assistant response should appear within timeout")
  end)
end)
