---@diagnostic disable: undefined-field
--- Command Code resumes with `--session`, not `--resume`.
---
--- `--resume <id>` resolves through the CLI's `hasCommandSession`, which is scoped to the project
--- directory of the cwd. A chat whose `working_dir` moved — a worktree removed and recreated under
--- a different name, a chat switched to another worktree — therefore failed with
--- `No session "<id>" found to resume.` and the session was discarded: the buffer still looked
--- continuous, but the conversation behind it was gone. `--session <id>` resolves against
--- `listAllSessionsV3` (every project) and loads a transcript that lives elsewhere with
--- `loadExternalPrintSession`, so the conversation follows the chat into the new directory.
--- Measured on 1.88.2; the reasoning lives in `handbook/architecture/cli-integration.md`.
local descriptor = require("vibing.infrastructure.adapter.backends.commandcode")
local helper = require("tests.helpers.adapter_stream")

local CONFIG = { ai = { chat = { model = "sonnet" } } }
local SESSION = "11111111-2222-3333-4444-555555555555"

--- The value that follows `flag` in an argv.
--- @param argv string[]
--- @param flag string
--- @return string|nil
local function value_after(argv, flag)
  for i, token in ipairs(argv) do
    if token == flag then
      return argv[i + 1]
    end
  end
end

describe("commandcode resume", function()
  local original_exepath

  before_each(function()
    original_exepath = vim.fn.exepath
    vim.fn.exepath = function()
      return helper.fake_binary("commandcode")
    end
    helper.reset_path_caches()
  end)

  after_each(function()
    vim.fn.exepath = original_exepath
    helper.reset_path_caches()
  end)

  it("hands the session id to --session", function()
    local cmd = descriptor.build("hi", {}, SESSION, CONFIG, nil)
    assert.equals(SESSION, value_after(cmd, "--session"))
  end)

  it("never passes --resume", function()
    -- The old spelling, pinned as absent: it is the one that loses the session on a cwd change,
    -- and an argv carrying both would still be read as a project-scoped resume.
    local cmd = descriptor.build("hi", {}, SESSION, CONFIG, nil)
    assert.is_nil(value_after(cmd, "--resume"))
  end)

  it("still forks with --fork-session right after the id", function()
    local cmd = descriptor.build("hi", { _is_fork = true }, SESSION, CONFIG, nil)
    local session = vim.fn.index(cmd, "--session")
    local fork = vim.fn.index(cmd, "--fork-session")
    assert.is_true(session > -1 and fork == session + 2, "unexpected argv: " .. vim.inspect(cmd))
  end)

  it("leaves the session to the acp handshake on duplex", function()
    -- `commandcode acp` resumes through `session/load`, not a flag; that path still cannot cross a
    -- working_dir change (see the handbook note), so it must at least not look as if it does.
    local cmd = descriptor.build("hi", { _process_model = "duplex" }, SESSION, CONFIG, nil)
    assert.is_nil(value_after(cmd, "--session"))
  end)
end)
