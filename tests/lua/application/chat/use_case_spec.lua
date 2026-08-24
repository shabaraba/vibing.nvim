-- Tests for `use_case.create_new`'s optional working_dir.
--
-- The guard here is deliberately not left to the caller. `create_chat.lua` happens to filter an
-- empty working_dir before it ever reaches this function, but deciding the default is this
-- function's job, and in Lua `""` is truthy — so `opts.working_dir or <default>` silently keeps
-- the empty string and writes `working_dir:` into the frontmatter with nothing after it.

local ChatBuffers = require("tests.helpers.chat_buffers")

describe("chat use_case.create_new", function()
  local use_case

  before_each(function()
    ChatBuffers.setup()
    use_case = require("vibing.application.chat.use_case")
  end)

  after_each(ChatBuffers.reset)

  it("derives working_dir from the cwd when no opts are given", function()
    local Git = require("vibing.core.utils.git")

    local session = use_case.create_new()

    assert.equals(Git.get_relative_path(vim.fn.getcwd()), session.working_dir)
  end)

  it("uses an explicit working_dir as given", function()
    local session = use_case.create_new({ working_dir = "some/where" })

    assert.equals("some/where", session.working_dir)
    assert.equals("some/where", session.frontmatter.working_dir)
  end)

  it("falls back to the cwd default when working_dir is the empty string", function()
    local Git = require("vibing.core.utils.git")

    local session = use_case.create_new({ working_dir = "" })

    assert.equals(Git.get_relative_path(vim.fn.getcwd()), session.working_dir)
    assert.are_not.equal("", session.working_dir)
  end)
end)

describe("chat use_case.generate_and_insert_summary", function()
  local use_case

  before_each(function()
    use_case = require("vibing.application.chat.use_case")
  end)

  it("refuses while a response is streaming", function()
    -- The summary goes in just below `# Vibing Chat` with nvim_buf_set_lines, so writing it
    -- while the stream appends at the end shifts the line numbers under the streaming handler.
    -- Symmetrical with the guard :VibingSetFileTitle has had since #475.
    local extracted = false
    local chat_buffer = {
      buf = vim.api.nvim_create_buf(false, true),
      is_sending = function()
        return true
      end,
      extract_conversation = function()
        extracted = true
        return { { role = "user", content = "hi" } }
      end,
    }

    use_case.generate_and_insert_summary(chat_buffer)

    assert.is_false(extracted)
  end)
end)
