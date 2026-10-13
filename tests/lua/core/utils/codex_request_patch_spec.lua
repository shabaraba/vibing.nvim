local Permission = require("vibing.infrastructure.rpc.handlers.permission")
local Vocabulary = require("vibing.infrastructure.adapter.modules.codex_tool_vocabulary")
local RequestDiff = require("vibing.core.utils.request_diff")
local Snapshot = require("vibing.core.utils.git_snapshot")
local SendMessage = require("vibing.application.chat.send_message")

describe("Codex request patch fallback", function()
  local dir
  local turn = "codex-patch-regression"
  local function write(name, text)
    vim.fn.writefile(vim.split(text, "\n", { plain = true }), dir .. "/" .. name, "b")
  end
  before_each(function()
    dir = vim.fn.fnamemodify(vim.fn.tempname(), ":p"):gsub("/$", "")
    vim.fn.mkdir(dir, "p")
  end)
  after_each(function()
    RequestDiff.clear(turn)
    Snapshot.clear(turn)
    vim.fn.delete(dir, "rf")
  end)

  it("writes a reversible multi-file patch from hook backups using the chat cwd", function()
    write("update.txt", "before\n")
    write("delete.txt", "deleted\n")
    write("old.txt", "original\n")
    write("unrelated.txt", "other chat before\n")
    local name, input = Permission.normalize_hook_input({
      tool_name = "apply_patch",
      tool_input = {
        command = table.concat({
          "*** Begin Patch",
          "*** Update File: update.txt",
          "@@",
          "-before",
          "+after",
          "*** Add File: new file.txt",
          "+created",
          "*** Delete File: delete.txt",
          "*** Update File: old.txt",
          "*** Move to: moved.txt",
          "@@",
          "-original",
          "+moved",
          "*** End Patch",
        }, "\n"),
      },
    }, Vocabulary)
    Permission._capture_baselines(turn, dir, name, input)
    write("update.txt", "intermediate\n")
    Permission._capture_baselines(turn, dir, name, input)
    write("update.txt", "after\n")
    write("new file.txt", "created\n")
    vim.fn.delete(dir .. "/delete.txt")
    vim.fn.delete(dir .. "/old.txt")
    write("moved.txt", "moved\n")
    write("unrelated.txt", "other chat after\n")

    local output = {}
    SendMessage._finalize_request_diff({
      get_cwd = function()
        return dir
      end,
      append_chunk = function(chunk)
        table.insert(output, chunk)
      end,
      add_user_section = function() end,
    }, turn, {})
    local rendered = table.concat(output)
    assert.is_truthy(rendered:find("5 files changed", 1, true))
    local path = rendered:match("Patch: ([^\n]+)")
    assert.is_truthy(path, rendered)
    local patch = table.concat(vim.fn.readfile(path), "\n")
    assert.is_falsy(patch:find("unrelated.txt", 1, true))
    assert.is_falsy(patch:find("intermediate", 1, true))
    local reversed = vim.system({ "git", "apply", "--reverse", path }, { cwd = dir, text = true }):wait()
    assert.equals(0, reversed.code, reversed.stderr)
    assert.same({ "before" }, vim.fn.readfile(dir .. "/update.txt"))
    assert.same({ "deleted" }, vim.fn.readfile(dir .. "/delete.txt"))
    assert.same({ "original" }, vim.fn.readfile(dir .. "/old.txt"))
    assert.equals(0, vim.fn.filereadable(dir .. "/new file.txt"))
    assert.equals(0, vim.fn.filereadable(dir .. "/moved.txt"))
    assert.same({ "other chat after" }, vim.fn.readfile(dir .. "/unrelated.txt"))
  end)
end)
