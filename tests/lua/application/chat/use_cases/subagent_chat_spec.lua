local SubagentChat = require("vibing.application.chat.use_cases.subagent_chat")
local Frontmatter = require("vibing.infrastructure.storage.frontmatter")

local AGENT_ID = "ab2e2379a4f9c8c52"

local function make_chat_buffer(opts)
  opts = opts or {}
  local buf = vim.api.nvim_create_buf(false, true)
  local file_path = opts.file_path or (vim.fn.tempname() .. ".md")

  local frontmatter = opts.frontmatter or {
    ["vibing.nvim"] = true,
    session_id = opts.session_id or "test-session-123",
    created_at = "2025-01-01T00:00:00",
    mode = "code",
    model = "opus",
    permission_mode = "bypassPermissions",
    permissions_allow = { "Read", "Edit" },
    permissions_deny = { "Bash" },
    working_dir = opts.working_dir,
  }

  local body = string.format("\n## User\n\nhi\n\n<!-- subagent: %s type=general-purpose -->\n", AGENT_ID)
  local content = Frontmatter.serialize(frontmatter, body)
  vim.fn.writefile(vim.split(content, "\n"), file_path)
  vim.api.nvim_buf_set_name(buf, file_path)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(content, "\n"))

  return { buf = buf, file_path = file_path, session_id = frontmatter.session_id }
end

local function setup_config()
  local tmp_dir = vim.fn.tempname() .. "_chat/"
  vim.fn.mkdir(tmp_dir, "p")

  package.loaded["vibing"] = {
    get_config = function()
      return {
        agent = { default_mode = "code", default_model = "sonnet" },
        permissions = { mode = "acceptEdits", allow = { "Read" }, deny = {} },
        chat = { save_location_type = "custom", save_dir = tmp_dir },
      }
    end,
  }
  return tmp_dir
end

local function read_frontmatter(path)
  return Frontmatter.parse(table.concat(vim.fn.readfile(path), "\n"))
end

describe("SubagentChat use case", function()
  local save_dir

  before_each(function()
    save_dir = setup_config()
  end)

  after_each(function()
    package.loaded["vibing"] = nil
  end)

  it("binds the new chat to the agent while keeping the parent's session", function()
    local source = make_chat_buffer()

    local session, existing = SubagentChat.execute(source, AGENT_ID)

    assert.is_nil(existing)
    assert.is_not_nil(session)
    local fm = read_frontmatter(session.file_path)
    assert.equals("test-session-123", fm.session_id)
    assert.equals(AGENT_ID, fm.subagent_id)
  end)

  it("never marks the chat as a fork", function()
    -- forked_from would make the command builder emit --fork-session, and a forked session cannot
    -- see the parent's agent transcripts — SendMessage fails with "No transcript found".
    local session = SubagentChat.execute(make_chat_buffer(), AGENT_ID)
    assert.is_nil(read_frontmatter(session.file_path).forked_from)
  end)

  it("inherits the parent's permission posture rather than the config defaults", function()
    local session = SubagentChat.execute(make_chat_buffer(), AGENT_ID)

    local fm = read_frontmatter(session.file_path)
    assert.equals("bypassPermissions", fm.permission_mode)
    assert.equals("opus", fm.model)
    assert.same({ "Read", "Edit" }, fm.permissions_allow)
    assert.same({ "Bash" }, fm.permissions_deny)
  end)

  it("carries the parent's working_dir so the worktree stays attached", function()
    local source = make_chat_buffer({ working_dir = ".vibing/worktrees/feat-x" })
    local session = SubagentChat.execute(source, AGENT_ID)

    assert.equals(".vibing/worktrees/feat-x", read_frontmatter(session.file_path).working_dir)
  end)

  it("reopens the existing chat instead of creating a rival for the same agent", function()
    local source = make_chat_buffer()
    local first = SubagentChat.execute(source, AGENT_ID)

    local session, existing = SubagentChat.execute(source, AGENT_ID)

    -- Two buffers bound to one agent would share a session_id and block each other's sends.
    assert.is_nil(session)
    assert.equals(first.file_path, existing)
  end)

  it("refuses a chat that has no session to resume yet", function()
    local source = make_chat_buffer({ session_id = "~" })
    local session, existing = SubagentChat.execute(source, AGENT_ID)

    assert.is_nil(session)
    assert.is_nil(existing)
  end)

  it("refuses without an agent id", function()
    assert.is_nil(SubagentChat.execute(make_chat_buffer(), ""))
    assert.is_nil(SubagentChat.execute(make_chat_buffer(), nil))
  end)

  it("does not leave a marker that would list itself as a subagent to continue", function()
    local session = SubagentChat.execute(make_chat_buffer(), AGENT_ID)

    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.fn.readfile(session.file_path))
    local finder = require("vibing.presentation.chat.modules.subagent_finder")
    assert.same({}, finder.find_all(buf))
  end)

  it("writes the file into the configured save directory", function()
    local session = SubagentChat.execute(make_chat_buffer(), AGENT_ID)
    assert.is_truthy(session.file_path:find(save_dir, 1, true))
    assert.equals(1, vim.fn.filereadable(session.file_path))
  end)
end)
