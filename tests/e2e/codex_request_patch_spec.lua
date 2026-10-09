-- Real apply_patch + a held snapshot force the overlapping-turn fallback (#875).
local helper = require("vibing.testing.e2e_helper")
if not helper.should_run() then
  return
end

local RESPONSE_MS = 60000

describe("E2E: Codex patch during an overlapping turn", function()
  local instance
  before_each(function()
    instance = helper.spawn_backend_instance("codex")
  end)
  after_each(function()
    helper.cleanup_instance(instance)
  end)

  it("writes a patch from the real pre-tool hook instead of only a file list", function()
    local initialized = vim.fn.rpcrequest(
      instance.job_id,
      "nvim_exec_lua",
      [[
      local root = ...
      vim.fn.writefile({ "before" }, root .. "/update.txt")
      local Snapshot = require("vibing.core.utils.git_snapshot")
      Snapshot.ensure_baseline("held-competing-turn", root, "Bash")
      return Snapshot.get_root("held-competing-turn") ~= nil
    ]],
      { instance.repo_dir }
    )
    assert.is_true(initialized, "the competing turn must hold a snapshot")
    helper.send_keys(instance, ":VibingChat<CR>")
    assert.is_true(helper.wait_for_buffer_name(instance, "%.md$", 5000))
    vim.fn.rpcrequest(
      instance.job_id,
      "nvim_exec_lua",
      [[
      local chat = require("vibing.presentation.chat.view")._current_buffer
      chat:update_frontmatter("model", "gpt-6-luna")
      chat:update_frontmatter("effort", "low")
    ]],
      {}
    )
    local ready, reason = helper.wait_for_input_ready(instance, 15000)
    assert.is_true(ready, reason)
    helper.send_keys(
      instance,
      "GiUse apply_patch directly to change update.txt from before to after and create new.txt containing created. Do not use shell tools or MCP tools. Then reply DONE.<Esc><CR>"
    )
    local ok
    ok, reason = helper.wait_for_completed_turn(instance, 1, RESPONSE_MS)
    assert.is_true(ok, reason)
    local result = vim.fn.rpcrequest(
      instance.job_id,
      "nvim_exec_lua",
      [[
      local root = ...
      local chat = require("vibing.presentation.chat.view")._current_buffer
      local text = table.concat(vim.api.nvim_buf_get_lines(chat.buf, 0, -1, false), "\n")
      local path = text:match("Patch: ([^\n]+)")
      require("vibing.core.utils.git_snapshot").clear("held-competing-turn")
      if not path then return { error = text } end
      local patch = table.concat(vim.fn.readfile(path), "\n")
      local applied = vim.system({ "git", "apply", "--reverse", path }, { cwd = root, text = true }):wait()
      return {
        patch = patch, code = applied.code, error = applied.stderr,
        restored = vim.fn.readfile(root .. "/update.txt"),
        new_exists = vim.fn.filereadable(root .. "/new.txt"),
      }
    ]],
      { instance.repo_dir }
    )
    assert.is_string(result.patch, result.error)
    assert.is_truthy(result.patch:find("# vibing-request-diff base:", 1, true), "expected fallback patch")
    assert.is_truthy(result.patch:find("+after", 1, true))
    assert.is_truthy(result.patch:find("+created", 1, true))
    assert.equals(0, result.code, result.error)
    assert.same({ "before" }, result.restored)
    assert.equals(0, result.new_exists)
  end)
end)
