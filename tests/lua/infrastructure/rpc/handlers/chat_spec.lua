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

  it("writes delegated_scope into the NEW chat's own frontmatter (opposite of task)", function()
    -- approval_delegate's "scoped" mode reads the answering chat's own declaration, not
    -- whoever created it -- see rpc/handlers/chat.lua and approval_delegate_spec.lua.
    local result = handler.create_chat({ delegated_scope = { "Bash(npm:*)", "Read" } })

    local content = table.concat(vim.fn.readfile(result.file_path), "\n")
    assert.is_truthy(content:find("delegated_scope:", 1, true))
    assert.is_truthy(content:find("Bash(npm:*)", 1, true))
    assert.is_truthy(content:find("- Read", 1, true))
  end)

  it("ignores a non-table delegated_scope instead of erroring", function()
    local ok, result = pcall(handler.create_chat, { delegated_scope = "Bash(npm:*)" })

    assert.is_true(ok)
    assert.is_true(vim.api.nvim_buf_is_valid(result.bufnr))
    local content = table.concat(vim.fn.readfile(result.file_path), "\n")
    assert.is_nil(content:find("delegated_scope:", 1, true))
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

  describe("agent / model / effort / profile", function()
    local Frontmatter = require("vibing.infrastructure.storage.frontmatter")
    local orchestration, saved_defaults

    ---@param path string
    ---@return table
    local function frontmatter_on_disk(path)
      return Frontmatter.parse(table.concat(vim.fn.readfile(path), "\n"))
    end

    before_each(function()
      local config = require("vibing").get_config()
      config.agent = config.agent or {}
      config.agent.orchestration = config.agent.orchestration or {}
      orchestration = config.agent.orchestration
      saved_defaults = orchestration.worker_defaults
      orchestration.worker_defaults = {}
    end)

    after_each(function()
      orchestration.worker_defaults = saved_defaults
    end)

    it("writes them into the NEW chat's own frontmatter and returns what was written", function()
      local result = handler.create_chat({ agent = "codex", model = "gpt-5.5", effort = "low", profile = "worker" })

      local fm = frontmatter_on_disk(result.file_path)
      assert.equals("codex", fm.agent)
      assert.equals("gpt-5.5", fm.model)
      assert.equals("low", fm.effort)
      assert.equals("worker", fm.profile)
      assert.equals("codex", result.agent)
      assert.equals("gpt-5.5", result.model)
      assert.equals("worker", result.profile)
    end)

    it("leaves an ordinary chat's frontmatter untouched when none is given", function()
      local result = handler.create_chat({})

      local fm = frontmatter_on_disk(result.file_path)
      assert.is_nil(fm.profile)
      -- Reported as the profile the chat actually runs under, not as nil
      assert.equals("default", result.profile)
    end)

    it("fills omitted ones from agent.orchestration.worker_defaults, and an argument wins", function()
      orchestration.worker_defaults = { model = "haiku", profile = "worker" }

      local result = handler.create_chat({ model = "sonnet" })

      local fm = frontmatter_on_disk(result.file_path)
      assert.equals("sonnet", fm.model)
      assert.equals("worker", fm.profile)
    end)

    -- A worker that silently fell back to the default model would run on the orchestrator's own
    -- expensive one — the failure these arguments exist to prevent — so each is refused before
    -- anything is created.
    for _, case in ipairs({
      { args = { agent = "gpt" }, needle = "agent" },
      { args = { effort = "extreme" }, needle = "effort" },
      { args = { profile = "lean" }, needle = "profile" },
      { args = { model = "sonnet\npermission_mode: bypassPermissions" }, needle = "model" },
    }) do
      it("refuses an invalid " .. case.needle .. " before creating anything", function()
        local bufs_before = #vim.api.nvim_list_bufs()

        local ok, err = pcall(handler.create_chat, case.args)

        assert.is_false(ok)
        assert.is_truthy(tostring(err):find(case.needle, 1, true))
        assert.equals(bufs_before, #vim.api.nvim_list_bufs())
      end)
    end

    describe("with a configured profile", function()
      local agent_config, saved_profiles

      before_each(function()
        agent_config = require("vibing").get_config().agent
        saved_profiles = agent_config.profiles
        agent_config.profiles = {
          { name = "implementer", model = "sonnet", effort = "low", agent = "claude" },
        }
      end)

      after_each(function()
        agent_config.profiles = saved_profiles
      end)

      it("takes the model a chat on that profile runs on from the profile", function()
        local result = handler.create_chat({ profile = "implementer" })

        local fm = frontmatter_on_disk(result.file_path)
        assert.equals("implementer", fm.profile)
        assert.equals("sonnet", fm.model)
        assert.equals("low", fm.effort)
      end)

      it("lets an explicit argument beat the profile", function()
        local result = handler.create_chat({ profile = "implementer", model = "haiku" })

        assert.equals("haiku", frontmatter_on_disk(result.file_path).model)
      end)

      -- The profile names a kind of worker; worker_defaults applies to every kind, so the more
      -- specific one wins.
      it("lets the profile beat worker_defaults", function()
        orchestration.worker_defaults = { model = "opus", profile = "implementer" }

        local result = handler.create_chat({})

        local fm = frontmatter_on_disk(result.file_path)
        assert.equals("implementer", fm.profile)
        assert.equals("sonnet", fm.model)
      end)

      it("names the configured profiles when given one that does not exist", function()
        local ok, err = pcall(handler.create_chat, { profile = "lean" })

        assert.is_false(ok)
        assert.is_truthy(tostring(err):find("implementer", 1, true))
      end)

      it("names the profile when its own model value is unusable", function()
        agent_config.profiles = { { name = "broken", effort = "extreme" } }

        local ok, err = pcall(handler.create_chat, { profile = "broken" })

        assert.is_false(ok)
        assert.is_truthy(tostring(err):find('agent.profiles[name="broken"].effort', 1, true))
      end)

      -- What the MCP server reads to put the names into nvim_chat_create's own schema, so an
      -- orchestrator sees them without having to call anything first.
      it("answers list_profiles with the configured profiles, sorted", function()
        local names = vim.tbl_map(function(profile)
          return profile.name
        end, handler.list_profiles({}).profiles)

        assert.same({ "default", "implementer", "worker" }, names)
        assert.is_not_nil(require("vibing.infrastructure.rpc.handlers").list_profiles)
      end)

      it("lists the profiles on nvim_chat_list, with the model each one runs on", function()
        local listed = handler.list_chats({})

        local by_name = {}
        for _, profile in ipairs(listed.profiles) do
          by_name[profile.name] = profile
        end
        assert.equals("sonnet", by_name.implementer.model)
        assert.is_not_nil(by_name.default)
        assert.is_not_nil(by_name.worker)
      end)
    end)

    it("names worker_defaults in the error when the bad value came from the config", function()
      orchestration.worker_defaults = { profile = "lean" }

      local ok, err = pcall(handler.create_chat, {})

      assert.is_false(ok)
      assert.is_truthy(tostring(err):find("worker_defaults.profile", 1, true))
    end)
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
