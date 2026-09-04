-- Tests for carrying an unsent message into a fresh chat: the file that gets written, what the
-- new frontmatter inherits, and what is left behind in the source buffer.

describe("carry_over", function()
  local CarryOver = require("vibing.application.chat.use_cases.carry_over")
  local ChatBuffer = require("vibing.presentation.chat.buffer")

  local vibing = require("vibing")
  local original_get_config
  local tmp_root
  local created_bufs

  before_each(function()
    tmp_root = vim.fn.tempname()
    vim.fn.mkdir(tmp_root, "p")
    original_get_config = vibing.get_config
    vibing.get_config = function()
      return {
        adapter = "claude",
        agent = { default_mode = "code", default_model = "sonnet" },
        permissions = { mode = "acceptEdits", allow = { "Read" }, deny = {} },
        chat = { save_location_type = "custom", save_dir = tmp_root },
      }
    end
    created_bufs = {}
  end)

  after_each(function()
    vibing.get_config = original_get_config
    for _, bufnr in ipairs(created_bufs) do
      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end
    vim.fn.delete(tmp_root, "rf")
  end)

  --- @param message string
  --- @return table chat_buffer
  local function make_source(message)
    -- A real, writable, named buffer: `execute` saves the source after emptying its unsent
    -- section, and a scratch buffer would exercise only the warn-and-continue path.
    local bufnr = vim.api.nvim_create_buf(false, false)
    table.insert(created_bufs, bufnr)
    vim.api.nvim_buf_set_name(bufnr, tmp_root .. "/source.md")
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
      "---",
      "vibing.nvim: true",
      "session_id: abc-123",
      "model: opus",
      "working_dir: .vibing/worktrees/thing",
      "---",
      "",
      "## User <!-- 2026-09-04 10:00:00 -->",
      "",
      "earlier",
      "",
      "## Assistant <!-- 2026-09-04 10:05:00 -->",
      "",
      "reply",
      "",
      "## User <!-- unsent -->",
      "",
      message,
      "",
    })
    -- nvim_buf_set_name resolves symlinks in an existing directory (macOS /tmp -> /private/tmp),
    -- so read the stored name back rather than assuming the path round-trips.
    local file_path = vim.api.nvim_buf_get_name(bufnr)
    return setmetatable({ buf = bufnr, file_path = file_path }, ChatBuffer), file_path
  end

  --- @param session table
  --- @return string
  local function read_new_file(session)
    return table.concat(vim.fn.readfile(session:get_file_path()), "\n")
  end

  it("writes the message into the new chat's unsent User section", function()
    local source = make_source("carry me over")

    local session, err = CarryOver.execute(source, "carry me over")

    assert.is_nil(err)
    assert.is_not_nil(session)
    assert.is_truthy(read_new_file(session):find("## User <!-- unsent -->\n\ncarry me over", 1, true))
  end)

  it("inherits the source's settings but never its session", function()
    local source = make_source("carry me over")

    local session = CarryOver.execute(source, "carry me over")

    local content = read_new_file(session)
    assert.is_truthy(content:find("model: opus", 1, true))
    assert.is_truthy(content:find("working_dir: .vibing/worktrees/thing", 1, true))
    assert.is_truthy(content:find("session_id: ~", 1, true))
    assert.is_nil(content:find("abc-123", 1, true))
  end)

  it("names the file after the source, like a handoff does", function()
    local source = make_source("carry me over")

    local first = CarryOver.execute(source, "carry me over")
    local second = CarryOver.execute(source, "carry me over again")

    assert.equals("source-continued-1.md", vim.fn.fnamemodify(first:get_file_path(), ":t"))
    assert.equals("source-continued-2.md", vim.fn.fnamemodify(second:get_file_path(), ":t"))
  end)

  it("empties the source's unsent section so the message lives in one place", function()
    local source, source_path = make_source("carry me over")

    CarryOver.execute(source, "carry me over")

    assert.is_nil(source:extract_user_message())
    local lines = vim.api.nvim_buf_get_lines(source.buf, 0, -1, false)
    assert.equals("## User <!-- unsent -->", lines[#lines - 1])
    -- and it is on disk, so reopening the source does not resurrect the moved message
    assert.is_false(vim.bo[source.buf].modified)
    assert.is_nil(table.concat(vim.fn.readfile(source_path), "\n"):find("carry me over", 1, true))
  end)

  it("refuses an empty message rather than creating a blank chat", function()
    local source = make_source("carry me over")

    local session, err = CarryOver.execute(source, "   ")

    assert.is_nil(session)
    assert.is_truthy(err)
  end)
end)
