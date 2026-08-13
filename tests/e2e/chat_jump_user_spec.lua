-- E2E Tests for :VibingChatJumpNextUser / :VibingChatJumpPrevUser
local helper = require("vibing.testing.e2e_helper")

-- tests/e2e is swept by `test:lua` too, and some of these specs send a real request to the CLI.
-- Only `test:e2e` sets VIBING_E2E=1; everything else skips rather than quietly spending tokens.
if not helper.should_run() then
  return
end

local TIMEOUTS = {
  CHAT_CREATION = 2000,
  BUFFER_READY = 5000,
  COMMAND = 300,
}

-- 別インスタンスへの同期RPC呼び出し（失敗時はテストを落とす）
local function rpc(instance, method, ...)
  local ok, res = pcall(vim.fn.rpcrequest, instance.job_id, method, ...)
  assert.is_true(ok, string.format("RPC %s failed: %s", method, tostring(res)))
  return res
end

-- チャットバッファに既知のUser/Assistantセクションを流し込む。
-- User見出しは1行目と5行目に来る（下のレイアウト参照）。
local function seed_sections(instance)
  local bufnr = rpc(instance, "nvim_get_current_buf")
  rpc(instance, "nvim_buf_set_option", bufnr, "modifiable", true)
  rpc(instance, "nvim_buf_set_lines", bufnr, 0, -1, false, {
    "## User", -- line 1
    "first question",
    "## Assistant",
    "first answer",
    "## User", -- line 5
    "second question",
    "## Assistant",
    "second answer",
  })
  return bufnr
end

local function cursor_line(instance)
  local pos = rpc(instance, "nvim_win_get_cursor", 0)
  return pos[1]
end

describe("E2E: Jump to User section", function()
  local nvim_instance

  before_each(function()
    nvim_instance = helper.spawn_nvim_instance({
      headless = true,
      init_script = "tests/e2e_init.lua",
    })

    helper.send_keys(nvim_instance, ":VibingChat<CR>")
    vim.wait(TIMEOUTS.CHAT_CREATION)
    local ok = helper.wait_for_buffer_name(nvim_instance, "%.md$", TIMEOUTS.BUFFER_READY)
    assert.is_true(ok, "Chat buffer should be created")

    seed_sections(nvim_instance)
  end)

  after_each(function()
    helper.cleanup_instance(nvim_instance)
  end)

  it("jumps forward to the next User section", function()
    rpc(nvim_instance, "nvim_win_set_cursor", 0, { 1, 0 })

    helper.send_keys(nvim_instance, ":VibingChatJumpNextUser<CR>")
    vim.wait(TIMEOUTS.COMMAND)

    assert.are.equal(5, cursor_line(nvim_instance), "Cursor should move to the second User header")
  end)

  it("jumps backward to the previous User section", function()
    -- 5行目のUser見出しから後方ジャンプ → 1行目の最初のUser見出しへ
    rpc(nvim_instance, "nvim_win_set_cursor", 0, { 5, 0 })

    helper.send_keys(nvim_instance, ":VibingChatJumpPrevUser<CR>")
    vim.wait(TIMEOUTS.COMMAND)

    assert.are.equal(1, cursor_line(nvim_instance), "Cursor should move to the first User header")
  end)

  it("stays put when there is no next User section", function()
    rpc(nvim_instance, "nvim_win_set_cursor", 0, { 5, 0 })

    helper.send_keys(nvim_instance, ":VibingChatJumpNextUser<CR>")
    vim.wait(TIMEOUTS.COMMAND)

    assert.are.equal(5, cursor_line(nvim_instance), "Cursor should not move past the last User header")
  end)
end)
