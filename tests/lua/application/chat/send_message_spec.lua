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

  describe("_handle_response pending-entry cleanup", function()
    local PendingResume = require("vibing.infrastructure.storage.pending_resume")
    local tmp_root

    before_each(function()
      tmp_root = vim.fn.tempname()
      vim.fn.mkdir(tmp_root, "p")
    end)

    after_each(function()
      if tmp_root then
        vim.fn.delete(tmp_root, "rf")
      end
    end)

    --- Store `entry` for a chat, then run a turn on it that ends with a plain error: not a usage
    --- limit, not a success.
    ---@param entry table Pending entry; its chat_file_path is filled in here.
    ---@return string chat_path The key the entry was stored under.
    local function handle_errored_turn(entry)
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_name(buf, tmp_root .. "/chat.md")
      -- _handle_response keys the store by the buffer's name, and Neovim resolves that (on macOS
      -- /var is a symlink to /private/var), so the entry has to be stored under the resolved one.
      local chat_path = vim.api.nvim_buf_get_name(buf)
      entry.chat_file_path = chat_path
      PendingResume.put(entry)

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
        supports = function(_, _feature)
          return false
        end,
      }

      SendMessage._handle_response({ error = "stream closed" }, callbacks, adapter, {}, {}, {}, "do the thing")

      vim.api.nvim_buf_delete(buf, { force = true })
      return chat_path
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

  describe("_merge_modified_files", function()
    it("resolves mote-relative paths against each batch's own base", function()
      local result = SendMessage._merge_modified_files({
        { base = "/repo/workspaces/app-a", files = { "src/main.lua" } },
        { base = "/repo/workspaces/app-b", files = { "src/main.lua" } },
      }, nil)

      -- 別mote_dirsの同名相対パスが衝突せず両方残ること
      assert.same({
        "/repo/workspaces/app-a/src/main.lua",
        "/repo/workspaces/app-b/src/main.lua",
      }, result)
    end)

    it("keeps absolute mote paths as-is", function()
      local result = SendMessage._merge_modified_files({
        { base = "/repo", files = { "/repo/src/a.lua", "src/b.lua" } },
      }, nil)

      assert.same({ "/repo/src/a.lua", "/repo/src/b.lua" }, result)
    end)

    it("unions tool-event paths and dedupes against mote results", function()
      local result = SendMessage._merge_modified_files({
        { base = "/repo", files = { "src/a.lua" } },
      }, {
        ["/repo/src/a.lua"] = true,
        ["/repo/src/only-tool-event.lua"] = true,
      })

      assert.equals(2, #result)
      assert.equals("/repo/src/a.lua", result[1])
      assert.equals("/repo/src/only-tool-event.lua", result[2])
    end)

    it("handles empty inputs", function()
      assert.same({}, SendMessage._merge_modified_files({}, nil))
      assert.same({}, SendMessage._merge_modified_files(nil, {}))
    end)

    it("strips trailing slashes from batch bases", function()
      local result = SendMessage._merge_modified_files({
        { base = "/repo/dir/", files = { "x.lua" } },
      }, nil)

      assert.same({ "/repo/dir/x.lua" }, result)
    end)
  end)
end)
