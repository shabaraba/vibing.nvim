local SendMessage = require("vibing.application.chat.send_message")

describe("send_message", function()
  describe("execute", function()
    it("propagates the sending chat buffer's file path as opts.chat_file_path", function()
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
      assert.equals(vim.api.nvim_buf_get_name(buf), captured.opts.chat_file_path)

      vim.api.nvim_buf_delete(buf, { force = true })
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
