local Fork = require("vibing.application.chat.use_cases.fork")
local Frontmatter = require("vibing.infrastructure.storage.frontmatter")

---テスト用のモックchat_bufferを作成
---@param opts? table
---@return table
local function make_chat_buffer(opts)
  opts = opts or {}
  local buf = vim.api.nvim_create_buf(false, true)
  local file_path = opts.file_path or (vim.fn.tempname() .. ".md")

  local frontmatter = opts.frontmatter or {
    ["vibing.nvim"] = true,
    session_id = opts.session_id or "test-session-123",
    created_at = "2025-01-01T00:00:00",
    mode = "code",
    model = "sonnet",
    permission_mode = "acceptEdits",
    permissions_allow = { "Read", "Edit" },
    permissions_deny = {},
  }

  local body = opts.body or "\n## 2025-01-01 00:00:00 User\n\nHello\n\n## 2025-01-01 00:01:00 Assistant\n\nHi there!\n"
  local content = Frontmatter.serialize(frontmatter, body)
  vim.fn.writefile(vim.split(content, "\n"), file_path)

  vim.api.nvim_buf_set_name(buf, file_path)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(content, "\n"))

  return {
    buf = buf,
    file_path = file_path,
    session_id = frontmatter.session_id,
    parse_frontmatter = function()
      return frontmatter
    end,
  }
end

---テスト用configのセットアップ
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

describe("Fork use case", function()
  local save_dir

  before_each(function()
    save_dir = setup_config()
  end)

  after_each(function()
    vim.fn.delete(save_dir, "rf")
    package.loaded["vibing"] = nil
  end)

  describe("execute", function()
    it("creates fork file with conversation history", function()
      local chat_buffer = make_chat_buffer()
      local fork_session = Fork.execute(chat_buffer)

      assert.is_not_nil(fork_session)
      local fork_path = fork_session:get_file_path()
      assert.is_not_nil(fork_path)
      assert.equals(1, vim.fn.filereadable(fork_path))

      local fork_content = table.concat(vim.fn.readfile(fork_path), "\n")
      local fork_fm, fork_body = Frontmatter.parse(fork_content)

      assert.is_not_nil(fork_fm)
      assert.equals("test-session-123", fork_fm.session_id)
      assert.is_truthy(fork_fm.forked_from)
      assert.is_truthy(fork_body:find("Hello"))
      assert.is_truthy(fork_body:find("Hi there!"))

      vim.fn.delete(chat_buffer.file_path)
    end)

    it("returns nil for nil chat_buffer", function()
      local result = Fork.execute(nil)
      assert.is_nil(result)
    end)

    it("returns nil for chat_buffer without file_path", function()
      local result = Fork.execute({ buf = 1 })
      assert.is_nil(result)
    end)

    it("increments fork number when file exists", function()
      local chat_buffer = make_chat_buffer()

      local fork1 = Fork.execute(chat_buffer)
      assert.is_not_nil(fork1)

      local fork2 = Fork.execute(chat_buffer)
      assert.is_not_nil(fork2)

      local path1 = fork1:get_file_path()
      local path2 = fork2:get_file_path()
      assert.is_not_nil(path1)
      assert.is_not_nil(path2)
      assert.are_not.equal(path1, path2)
      assert.is_truthy(path1:find("fork%-1%.md$"))
      assert.is_truthy(path2:find("fork%-2%.md$"))

      vim.fn.delete(chat_buffer.file_path)
    end)

    it("handles empty conversation body", function()
      local chat_buffer = make_chat_buffer({ body = "" })
      local fork_session = Fork.execute(chat_buffer)

      assert.is_not_nil(fork_session)
      local fork_path = fork_session:get_file_path()
      assert.equals(1, vim.fn.filereadable(fork_path))

      vim.fn.delete(chat_buffer.file_path)
    end)

    it("inherits session_id from source", function()
      local chat_buffer = make_chat_buffer({ session_id = "source-abc-123" })
      local fork_session = Fork.execute(chat_buffer)

      assert.is_not_nil(fork_session)
      local fork_path = fork_session:get_file_path()
      local fork_content = table.concat(vim.fn.readfile(fork_path), "\n")
      local fork_fm = Frontmatter.parse(fork_content)

      assert.equals("source-abc-123", fork_fm.session_id)

      vim.fn.delete(chat_buffer.file_path)
    end)

    it("uses fallback session_id when source has none", function()
      -- session_idフィールドなしのfrontmatterでファイルを作成
      local file_path = vim.fn.tempname() .. ".md"
      local fm = {
        ["vibing.nvim"] = true,
        created_at = "2025-01-01T00:00:00",
        mode = "code",
        model = "sonnet",
      }
      local body = "\n## 2025-01-01 00:00:00 User\n\nHello\n"
      local content = Frontmatter.serialize(fm, body)
      vim.fn.writefile(vim.split(content, "\n"), file_path)

      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_name(buf, file_path)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(content, "\n"))

      local chat_buffer = {
        buf = buf,
        file_path = file_path,
        session_id = nil,
        parse_frontmatter = function()
          return fm
        end,
      }

      local fork_session = Fork.execute(chat_buffer)
      assert.is_not_nil(fork_session)

      local fork_path = fork_session:get_file_path()
      local fork_content = table.concat(vim.fn.readfile(fork_path), "\n")
      local fork_fm = Frontmatter.parse(fork_content)

      assert.equals("~", fork_fm.session_id)

      vim.fn.delete(file_path)
    end)

    it("copies frontmatter fields from source", function()
      local chat_buffer = make_chat_buffer({
        frontmatter = {
          ["vibing.nvim"] = true,
          session_id = "test-session",
          created_at = "2025-01-01T00:00:00",
          mode = "plan",
          model = "opus",
          permission_mode = "bypassPermissions",
          permissions_allow = { "Read", "Edit", "Write" },
          permissions_deny = { "Bash" },
          language = "ja",
          working_dir = ".worktrees/feature",
        },
      })

      local fork_session = Fork.execute(chat_buffer)
      assert.is_not_nil(fork_session)

      local fork_path = fork_session:get_file_path()
      local fork_content = table.concat(vim.fn.readfile(fork_path), "\n")
      local fork_fm = Frontmatter.parse(fork_content)

      assert.equals("plan", fork_fm.mode)
      assert.equals("opus", fork_fm.model)
      assert.equals("bypassPermissions", fork_fm.permission_mode)
      assert.equals("ja", fork_fm.language)
      assert.equals(".worktrees/feature", fork_fm.working_dir)

      vim.fn.delete(chat_buffer.file_path)
    end)

    it("returns nil when source file is unreadable", function()
      local chat_buffer = make_chat_buffer()
      vim.fn.delete(chat_buffer.file_path)
      -- ファイルが存在しない状態でfork。auto_saveは失敗しないが、readfileが失敗する
      -- auto_saveが新規ファイルとして書き込む可能性があるため、バッファ内容を空にする
      vim.api.nvim_buf_set_lines(chat_buffer.buf, 0, -1, false, {})
      -- file_pathを存在しないパスに設定
      local nonexistent = vim.fn.tempname() .. "_nonexistent/file.md"
      chat_buffer.file_path = nonexistent
      local result = Fork.execute(chat_buffer)
      assert.is_nil(result)
    end)
  end)
end)
