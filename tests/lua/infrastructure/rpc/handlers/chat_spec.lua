-- Tests for the `create_chat` RPC method backing the nvim_chat_create MCP tool.
-- The orchestrator (claude-plugin/skills/vibing-orchestrate) has no other way to make a worker chat, and the
-- bufnr this returns is its only handle on that worker, so the return shape is the contract.

local ChatConstants = require("vibing.core.constants.chat")
local ChatBuffers = require("tests.helpers.chat_buffers")

describe("rpc handlers: create_chat", function()
  local handler, view

  before_each(function()
    ChatBuffers.setup()
    view = require("vibing.presentation.chat.view")
    handler = require("vibing.infrastructure.rpc.handlers.chat")
  end)

  after_each(ChatBuffers.reset)

  it("defaults to the windowless 'back' position so a worker never disturbs the layout", function()
    local win_count_before = #vim.api.nvim_list_wins()

    local result = handler.create_chat({})

    assert.equals("back", result.position)
    assert.equals(win_count_before, #vim.api.nvim_list_wins())
    assert.is_true(vim.api.nvim_buf_is_valid(result.bufnr))
  end)

  it("returns a chat file path that actually exists on disk", function()
    -- :VibingChat leaves the file unwritten until the first response comes back. Returning a
    -- path to the orchestrator only helps if the path is real, so the handler saves immediately.
    local result = handler.create_chat({})

    assert.is_true(result.saved)
    assert.equals(1, vim.fn.filereadable(result.file_path))
    local content = table.concat(vim.fn.readfile(result.file_path), "\n")
    assert.is_truthy(content:find("vibing.nvim: true", 1, true))
  end)

  it("registers the new buffer so nvim_chat_send_message can find it", function()
    local result = handler.create_chat({})

    assert.is_not_nil(view.get_chat_buffer(result.bufnr))
  end)

  it("leaves the user's own chat as the current one", function()
    -- view._current_buffer is the fallback :VibingCancel and :VibingToggleChat
    -- use when the cursor is outside a chat buffer. A worker created in the background is not
    -- the chat the user opened: letting it take that slot made :VibingCancel stop the worker
    -- instead of the user's in-flight request, and made :VibingToggleChat report the (windowless)
    -- worker as "not open" and open a third chat.
    local users_chat = view.render({ session_id = "the-user-chat" }, "right")
    assert.is_true(view.is_open())

    local worker = handler.create_chat({})

    assert.equals(users_chat.buf, view._current_buffer.buf)
    assert.is_true(view.is_open())
    -- ...and the worker is still reachable by bufnr, which is all the orchestrator needs
    assert.is_not_nil(view.get_chat_buffer(worker.bufnr))
  end)

  it("creates two independent worker buffers rather than reusing one", function()
    local first = handler.create_chat({})
    local second = handler.create_chat({})

    assert.are_not.equal(first.bufnr, second.bufnr)
    assert.are_not.equal(first.file_path, second.file_path)
  end)

  it("rejects a position outside the :VibingChat set instead of falling back silently", function()
    local ok, err = pcall(handler.create_chat, { position = "sideways" })

    assert.is_false(ok)
    assert.is_truthy(tostring(err):find("Invalid position", 1, true))
    for _, position in ipairs(ChatConstants.POSITIONS) do
      assert.is_truthy(tostring(err):find(position, 1, true))
    end
  end)

  it("rejects a from_bufnr that names no chat buffer, before creating anything", function()
    -- 典型は Neovim 再起動を跨いで会話履歴から使い回された番号（#661）。作成後に弾くと、
    -- 拒否されたのに空のワーカーチャットとそのファイルだけが残る
    local bufs_before = #vim.api.nvim_list_bufs()

    assert.has_error(function()
      handler.create_chat({ from_bufnr = 99999 })
    end)
    assert.equals(bufs_before, #vim.api.nvim_list_bufs())
  end)

  it("accepts a from_bufnr that names a real chat", function()
    local orchestrator = handler.create_chat({})

    local worker = handler.create_chat({ from_bufnr = orchestrator.bufnr })

    assert.is_true(vim.api.nvim_buf_is_valid(worker.bufnr))
  end)

  it("treats an explicit null from_bufnr as absent", function()
    local result = handler.create_chat({ from_bufnr = vim.NIL })

    assert.is_true(vim.api.nvim_buf_is_valid(result.bufnr))
  end)

  it("rejects a working_dir that does not exist", function()
    local ok, err = pcall(handler.create_chat, { working_dir = "nope/not/here" })

    assert.is_false(ok)
    assert.is_truthy(tostring(err):find("working_dir", 1, true))
  end)

  it("treats an empty working_dir as absent", function()
    local result = handler.create_chat({ working_dir = "" })

    assert.is_true(vim.api.nvim_buf_is_valid(result.bufnr))
  end)

  it("does not write task into the new chat's own frontmatter (#696 follow-up)", function()
    -- task's only home is the *orchestrator's* `orchestrated` entry (orchestration_link.lua),
    -- never the created chat's own file — see orchestration_link_spec.lua for where it lands.
    local orchestrator = handler.create_chat({})

    local result = handler.create_chat({ from_bufnr = orchestrator.bufnr, task = "PR #688 -- review" })

    local content = table.concat(vim.fn.readfile(result.file_path), "\n")
    assert.is_nil(content:find("\ntask:", 1, true))
  end)

  it("warns and drops task when given without from_bufnr, instead of losing it silently", function()
    local notify = require("vibing.core.utils.notify")
    local original_warn = notify.warn
    local warned = false
    notify.warn = function(message)
      warned = true
      assert.is_truthy(tostring(message):find("from_bufnr", 1, true))
    end

    local ok, result = pcall(handler.create_chat, { task = "PR #688 -- review" })
    notify.warn = original_warn

    assert.is_true(ok)
    assert.is_true(vim.api.nvim_buf_is_valid(result.bufnr))
    assert.is_true(warned)
  end)
end)

describe("rpc handlers: create_chat with working_dir", function()
  local handler, save_dir, repo, original_cwd

  before_each(function()
    original_cwd = vim.fn.getcwd()
    repo = vim.fn.tempname() .. "_repo"
    vim.fn.mkdir(repo .. "/sub", "p")
    vim.fn.system({ "git", "-C", repo, "init", "-q" })
    -- Git.get_root() resolves against Neovim's cwd, so the handler only sees this repo from here.
    vim.cmd("cd " .. vim.fn.fnameescape(repo))

    save_dir = ChatBuffers.setup()
    handler = require("vibing.infrastructure.rpc.handlers.chat")
  end)

  after_each(function()
    ChatBuffers.reset()
    vim.cmd("cd " .. vim.fn.fnameescape(original_cwd))
  end)

  it("writes the git-relative working_dir into the new chat's frontmatter", function()
    local result = handler.create_chat({ working_dir = "sub" })

    assert.equals("sub", result.working_dir)
    local content = table.concat(vim.fn.readfile(result.file_path), "\n")
    assert.is_truthy(content:find("working_dir: sub", 1, true))
  end)

  it("keeps the chat file in the configured save dir, not inside the working_dir", function()
    -- A worker attached to a worktree must outlive `git worktree remove`; storing its transcript
    -- under the worktree would delete the conversation along with the branch.
    local result = handler.create_chat({ working_dir = "sub" })

    assert.is_truthy(result.file_path:find(save_dir, 1, true))
    assert.is_nil(result.file_path:find("/sub/", 1, true))
  end)
end)
