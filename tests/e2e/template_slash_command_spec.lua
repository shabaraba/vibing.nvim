-- E2E Tests for the /template slash command
local helper = require("vibing.testing.e2e_helper")

local TIMEOUTS = {
  CHAT_CREATION = 2000,
  BUFFER_READY = 5000,
  CURSOR_MOVE = 100,
  DRAFT_INSERTED = 5000,
}

describe("E2E: /template slash command", function()
  local nvim_instance

  before_each(function()
    nvim_instance = helper.spawn_nvim_instance({
      headless = true,
      init_script = "tests/minimal_init.lua",
    })
  end)

  after_each(function()
    helper.cleanup_instance(nvim_instance)
  end)

  it("prefills an editable draft with auto-detected context", function()
    helper.send_keys(nvim_instance, ":VibingChat<CR>")
    vim.wait(TIMEOUTS.CHAT_CREATION)

    local ok = helper.wait_for_buffer_content(nvim_instance, "%.md", TIMEOUTS.BUFFER_READY)
    assert.is_true(ok, "Chat buffer should be created")

    helper.send_keys(nvim_instance, "G")
    vim.wait(TIMEOUTS.CURSOR_MOVE)

    helper.send_keys(nvim_instance, "i")
    helper.send_keys(nvim_instance, "/template ログイン画面のセッション切れバグを調査したい")
    helper.send_keys(nvim_instance, "<Esc>")
    helper.send_keys(nvim_instance, "<CR>")

    ok = helper.wait_for_buffer_content(
      nvim_instance,
      "タスク内容: ログイン画面のセッション切れバグを調査したい",
      TIMEOUTS.DRAFT_INSERTED
    )
    assert.is_true(ok, "Draft should contain the raw task description")

    ok = helper.wait_for_buffer_content(nvim_instance, "リポジトリ:", TIMEOUTS.DRAFT_INSERTED)
    assert.is_true(ok, "Draft should contain the auto-detected repository line")

    ok = helper.wait_for_buffer_content(nvim_instance, "既存の規約: CLAUDE.mdに従う", TIMEOUTS.DRAFT_INSERTED)
    assert.is_true(ok, "Draft should mention CLAUDE.md when one is detected")

    ok = helper.wait_for_buffer_content(nvim_instance, "AskUserQuestion", TIMEOUTS.DRAFT_INSERTED)
    assert.is_true(ok, "Draft should instruct the assistant to ask when unsure")
  end)
end)
