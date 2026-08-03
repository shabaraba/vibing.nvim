-- E2E: Grok CLI adapter smoke test
-- Skips when the official Grok Build CLI binary is not on PATH.
local helper = require("vibing.testing.e2e_helper")

local TIMEOUTS = {
  CHAT_CREATION = 2000,
  BUFFER_READY = 5000,
  FRONTMATTER = 2000,
  CURSOR_MOVE = 100,
  ASSISTANT_RESPONSE = 60000,
}

local function grok_available()
  local path = vim.fn.exepath("grok")
  if path == "" then
    return false
  end
  local version = vim.fn.system({ path, "--version" })
  return type(version) == "string" and version:match("^grok%s+%d+%.%d+") ~= nil
end

describe("E2E: Grok CLI adapter", function()
  if not grok_available() then
    pending("official Grok Build CLI not found in PATH — skipping")
    return
  end

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

  it("should respond with agent: grok in frontmatter", function()
    helper.send_keys(nvim_instance, ":VibingChat<CR>")
    vim.wait(TIMEOUTS.CHAT_CREATION)

    local ok = helper.wait_for_buffer_content(nvim_instance, "created_at:", TIMEOUTS.FRONTMATTER)
    assert.is_true(ok, "frontmatter should appear")

    -- Set agent: grok via frontmatter edit (append after first --- block field)
    helper.send_keys(nvim_instance, "gg")
    helper.send_keys(nvim_instance, "/created_at:<CR>")
    helper.send_keys(nvim_instance, "oagent: grok<Esc>")
    helper.send_keys(nvim_instance, ":w<CR>")
    vim.wait(500)

    helper.send_keys(nvim_instance, "G")
    vim.wait(TIMEOUTS.CURSOR_MOVE)
    helper.send_keys(nvim_instance, "i")
    helper.send_keys(nvim_instance, 'Say only the word "pong"')
    helper.send_keys(nvim_instance, "<Esc>")
    helper.send_keys(nvim_instance, "<CR>")

    ok = helper.wait_for_buffer_content(nvim_instance, "## .* Assistant", TIMEOUTS.ASSISTANT_RESPONSE)
    assert.is_true(ok, "Assistant response should appear when using Grok adapter")
  end)
end)
