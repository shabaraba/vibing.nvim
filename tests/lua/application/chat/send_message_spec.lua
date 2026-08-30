local SendMessage = require("vibing.application.chat.send_message")

describe("send_message", function()
  describe("execute", function()
    it("propagates the sending chat buffer's number to the adapter opts", function()
      local buf = vim.api.nvim_create_buf(false, true)
      local file_path = vim.fn.tempname() .. ".md"
      vim.api.nvim_buf_set_name(buf, file_path)

      local callbacks = {
        get_bufnr = function()
          return buf
        end,
        get_session_id = function()
          return "test-session"
        end,
        parse_frontmatter = function()
          return {}
        end,
        extract_conversation = function()
          return {}
        end,
        update_filename_from_message = function(_) end,
        start_response = function() end,
        get_session_allow = function()
          return {}
        end,
        get_session_deny = function()
          return {}
        end,
        add_user_section = function() end,
      }

      local captured = {}
      local adapter = {
        supports = function(_, _feature)
          return false
        end,
        execute = function(_, prompt, opts)
          captured.opts = opts
          captured.prompt = prompt
          return { content = "ok" }
        end,
      }

      SendMessage.execute(adapter, callbacks, "hello", {})

      assert.is_not_nil(captured.opts)
      assert.equals(buf, captured.opts.chat_bufnr)

      vim.api.nvim_buf_delete(buf, { force = true })
    end)
  end)

  describe("_handle_response", function()
    local PendingResume = require("vibing.infrastructure.storage.pending_resume")
    local LimitState = require("vibing.infrastructure.storage.limit_state")
    local tmp_root

    before_each(function()
      tmp_root = vim.fn.tempname()
      vim.fn.mkdir(tmp_root, "p")
      LimitState.clear_cache()
    end)

    after_each(function()
      if tmp_root then
        vim.fn.delete(tmp_root, "rf")
      end
    end)

    --- Run one turn through `_handle_response`, against a real, named scratch buffer.
    ---@param response table What the adapter produced: `{ content }`, `{ error }`, ...
    ---@param opts { adapter_name: string|nil, before: fun(chat_path: string)|nil }|nil
    ---  `adapter_name` is the adapter instance's `name` ("claude_cli", "codex_cli", ...), which is
    ---  how the handler tells which backend ran. `before` seeds a store once the chat's path is
    ---  known but before the turn runs.
    ---@return string chat_path The buffer's name, which is the key both stores use.
    local function handle_turn(response, opts)
      opts = opts or {}
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_name(buf, tmp_root .. "/chat.md")
      -- _handle_response keys the stores by the buffer's name, and Neovim resolves that (on macOS
      -- /var is a symlink to /private/var), so anything seeded here has to use the resolved one.
      local chat_path = vim.api.nvim_buf_get_name(buf)
      if opts.before then
        opts.before(chat_path)
      end

      local callbacks = {
        clear_sending = function() end,
        get_bufnr = function()
          return buf
        end,
        get_session_id = function()
          return nil
        end,
        update_session_id = function(_) end,
        append_chunk = function(_) end,
        add_user_section = function() end,
      }
      local adapter = {
        name = opts.adapter_name,
        supports = function(_, _feature)
          return false
        end,
      }

      SendMessage._handle_response(response, callbacks, adapter, {}, {}, "do the thing")

      vim.api.nvim_buf_delete(buf, { force = true })
      return chat_path
    end

    describe("pending-entry cleanup", function()
      --- Store `entry` for a chat, then run a turn on it that ends with a plain error: not a usage
      --- limit, not a success.
      ---@param entry table Pending entry; its chat_file_path is filled in here.
      ---@return string chat_path The key the entry was stored under.
      local function handle_errored_turn(entry)
        return handle_turn({ error = "stream closed" }, {
          before = function(chat_path)
            entry.chat_file_path = chat_path
            PendingResume.put(entry)
          end,
        })
      end

      it("drops a scheduled entry when the turn ends in a non-limit error", function()
        -- A scheduled request has no stored body — it sends whatever sits in the unsent `## User`
        -- section when it fires. This turn already consumed that section, so an entry outliving it
        -- would later send whatever landed there next (a half-typed follow-up, an approval or
        -- AskUserQuestion option block). Only a *successful* turn used to clear it.
        local chat_path = handle_errored_turn({
          kind = "scheduled",
          resets_at = os.time() + 7200,
          retry_count = 0,
          recorded_at = os.time(),
          state = "waiting",
        })

        assert.is_nil(PendingResume.get(chat_path))
      end)

      it("keeps an auto_resume entry when the turn ends in a non-limit error", function()
        -- The auto_resume contract is untouched: its budget only moves when a limit is observed,
        -- and an errored turn is no evidence the limit lifted.
        local chat_path = handle_errored_turn({
          kind = "auto_resume",
          resets_at = os.time() + 7200,
          retry_count = 1,
          recorded_at = os.time(),
          state = "waiting",
        })

        local entry = PendingResume.get(chat_path)
        assert.is_not_nil(entry)
        assert.equals("waiting", entry.state)
        assert.equals(1, entry.retry_count)

        PendingResume.remove(chat_path)
      end)
    end)

    describe("usage-limit record scoping", function()
      --- Run a successful turn on `adapter_name` against a chat whose project already has a
      --- claude limit on record. Seeding goes through `before` so the record lands in the same
      --- directory the handler resolves — seeding under the unresolved `tmp_root` would leave
      --- both assertions below passing against an empty store.
      ---@param adapter_name string
      ---@return string chat_dir
      local function succeed_under_claude_limit(adapter_name)
        local chat_path = handle_turn({ content = "ok" }, {
          adapter_name = adapter_name,
          before = function(path)
            local dir = vim.fn.fnamemodify(path, ":h")
            LimitState.record({ resets_at = os.time() + 3600 }, dir, "claude")
            assert.is_not_nil(LimitState.get_active(dir, "claude"), "fixture failed to seed the limit")
          end,
        })
        return vim.fn.fnamemodify(chat_path, ":h")
      end

      it("keeps a claude limit on record when a codex turn succeeds", function()
        -- A codex request getting through is no evidence Anthropic's plan limit lifted. Clearing
        -- it would send the next claude message straight into the rejection it was parked to
        -- avoid.
        local chat_dir = succeed_under_claude_limit("codex_cli")

        assert.is_not_nil(LimitState.get_active(chat_dir, "claude"))
      end)

      it("clears the claude limit when a claude turn succeeds", function()
        local chat_dir = succeed_under_claude_limit("claude_cli")

        assert.is_nil(LimitState.load(chat_dir))
      end)
    end)
  end)

  describe("_warn_removed_frontmatter", function()
    local messages
    local original_notify

    before_each(function()
      SendMessage._reset_removed_frontmatter_warnings()
      messages = {}
      original_notify = vim.notify
      vim.notify = function(msg, level)
        table.insert(messages, { msg = msg, level = level })
      end
    end)

    after_each(function()
      vim.notify = original_notify
      SendMessage._reset_removed_frontmatter_warnings()
    end)

    it("says nothing for frontmatter that carries no removed key", function()
      SendMessage._warn_removed_frontmatter({ model = "sonnet" })

      assert.equals(0, #messages)
    end)

    it("names every removed key it found, once", function()
      SendMessage._warn_removed_frontmatter({ mote_dirs = { "/repo" }, mote_cwd = "/repo" })
      SendMessage._warn_removed_frontmatter({ mote_dirs = { "/repo" }, mote_cwd = "/repo" })

      assert.equals(1, #messages)
      assert.is_truthy(messages[1].msg:find("mote_dirs", 1, true))
      assert.is_truthy(messages[1].msg:find("mote_cwd", 1, true))
      assert.equals(vim.log.levels.WARN, messages[1].level)
    end)

    it("tolerates a missing frontmatter table", function()
      SendMessage._warn_removed_frontmatter(nil)

      assert.equals(0, #messages)
    end)
  end)
end)
