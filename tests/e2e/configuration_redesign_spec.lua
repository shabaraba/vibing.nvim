local helper = require("vibing.testing.e2e_helper")
if not helper.should_run() then
  return
end

-- Critical: full setup -> chat frontmatter/storage, independent helper selection.
-- High: invalid setup is atomic and names its migration destination.
describe("E2E: configuration redesign", function()
  local instance
  before_each(function()
    instance = helper.spawn_nvim_instance({ headless = true, init_script = "tests/e2e_init.lua" })
  end)
  after_each(function()
    helper.cleanup_instance(instance)
  end)

  it("uses the new schema when creating a chat and resolving helpers", function()
    helper.setup_child(instance, {
      ai = {
        chat = { agent = "claude", model = "sonnet", effort = "high" },
        helpers = { agent = "codex", model = "helper-model", effort = "low" },
      },
      chat = { language = "ja" },
      ui = { window = { position = "current" } },
      permissions = { mode = "plan", ask = { "Bash" } },
    })
    helper.send_keys(instance, ":VibingChat<CR>")
    assert.is_true(helper.wait_for_buffer_name(instance, "%.md$", 5000))
    local state = vim.fn.rpcrequest(
      instance.job_id,
      "nvim_exec_lua",
      [[
      local v = require("vibing")
      return {
        lines = vim.api.nvim_buf_get_lines(0, 0, -1, false),
        helper = require("vibing.core.utils.ai_config").resolve(v.get_config(), nil, true),
        path = vim.uv.fs_realpath(vim.fs.dirname(vim.api.nvim_buf_get_name(0))),
        directory = vim.uv.fs_realpath(v.get_config().chat.storage.path),
      }
    ]],
      {}
    )
    local text = table.concat(state.lines, "\n")
    assert.truthy(text:find("agent: claude", 1, true))
    assert.truthy(text:find("model: sonnet", 1, true))
    assert.truthy(text:find("effort: high", 1, true))
    assert.truthy(text:find("permission_mode: plan", 1, true))
    assert.is_nil(text:match("\nmode:"))
    assert.same({ agent = "codex", model = "helper-model", effort = "low" }, state.helper)
    assert.equals(state.directory, state.path)
  end)

  it("rejects old keys without changing the running configuration", function()
    local result = vim.fn.rpcrequest(
      instance.job_id,
      "nvim_exec_lua",
      [[
      local v = require("vibing")
      local before = v.get_config()
      local ok, err = pcall(v.setup, {chat = {window = {position = "left"}}})
      return {ok = ok, error = err, unchanged = before == v.get_config()}
    ]],
      {}
    )
    assert.is_false(result.ok)
    assert.truthy(result.error:find("chat.window: moved to ui.window", 1, true))
    assert.is_true(result.unchanged)
  end)
end)
