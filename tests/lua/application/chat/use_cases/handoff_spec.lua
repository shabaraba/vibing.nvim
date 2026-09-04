-- `:VibingChatHandoff` の実体。押さえたいのは3点:
--   * 新しいチャットは元の session_id を持たない（持つと --resume で履歴ごと付いてくる）
--   * 要約は Read させるのではなく未送信 User セクションに直接書かれる
--   * 出自は `continued_from` で、`forked_from` は使わない（あれは --fork-session のフラグ）
local Handoff = require("vibing.application.chat.use_cases.handoff")
local Frontmatter = require("vibing.infrastructure.storage.frontmatter")
local Timestamp = require("vibing.core.utils.timestamp")

local SUMMARY = table.concat({
  "## summary",
  "",
  "### 📝 一行要約",
  "",
  "- 認証まわりのリファクタ方針を決めた",
  "",
  "### 🚧 未解決 / 次の一手",
  "",
  "- `auth.lua` のテストを書く",
}, "\n")

---@param opts? table
local function make_chat_buffer(opts)
  opts = opts or {}
  local file_path = opts.file_path or (vim.fn.tempname() .. "-source.md")

  local frontmatter = opts.frontmatter
    or {
      ["vibing.nvim"] = true,
      session_id = "session-source-123",
      created_at = "2025-01-01T00:00:00",
      forked_from = "somewhere-else.md",
      orchestrated_by = { "orchestrator.md" },
      working_dir = ".vibing/worktrees/auth",
      mode = "code",
      model = "opus",
      effort = "high",
      permission_mode = "acceptEdits",
      permissions_allow = { "Read", "Edit" },
      permissions_deny = { "Bash" },
      language = "ja",
    }

  local body = opts.body
    or "\n# Vibing Chat\n\n---\n\n## 2025-01-01 00:00:00 User\n\nHello\n\n## 2025-01-01 00:01:00 Assistant\n\nHi there!\n"
  local content = Frontmatter.serialize(frontmatter, body)
  vim.fn.writefile(vim.split(content, "\n", { plain = true }), file_path)

  -- 本物のチャットバッファと同じく、ファイルを読み込んだバッファにする。scratch バッファに
  -- 名前だけ付けると `:write` が E13（ファイルが存在する）で止まり、保存の検証ができない
  local buf = vim.fn.bufadd(file_path)
  vim.fn.bufload(buf)
  vim.bo[buf].swapfile = false

  return {
    buf = buf,
    file_path = file_path,
    session_id = frontmatter.session_id,
    parse_frontmatter = function()
      return frontmatter
    end,
  }
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

describe("Handoff use case", function()
  local save_dir

  before_each(function()
    save_dir = setup_config()
  end)

  after_each(function()
    vim.fn.delete(save_dir, "rf")
    package.loaded["vibing"] = nil
    package.loaded["vibing.application.chat.use_case"] = nil
  end)

  describe("strip_summary_heading", function()
    it("drops the `## summary` line and trims", function()
      assert.equals("### 📝 一行要約\n\n- 決めた", Handoff.strip_summary_heading("## summary\n\n### 📝 一行要約\n\n- 決めた\n"))
    end)

    it("is case-insensitive about the heading", function()
      assert.equals("body", Handoff.strip_summary_heading("## Summary\nbody"))
    end)

    it("returns nil for a heading with nothing under it", function()
      assert.is_nil(Handoff.strip_summary_heading("## summary\n\n"))
      assert.is_nil(Handoff.strip_summary_heading(nil))
    end)
  end)

  describe("build_body", function()
    it("puts the lead-in and the summary inside the unsent User section", function()
      local body = Handoff.build_body("### 📝 一行要約\n\n- 決めた", ".vibing/chat/source.md")
      local lines = vim.split(body, "\n", { plain = true })

      assert.equals("", lines[1])
      assert.equals("# Vibing Chat", lines[2])
      assert.equals("---", lines[4])
      assert.equals(Timestamp.create_unsent_user_header(), lines[6])
      assert.equals(string.format(Handoff.LEAD_IN, ".vibing/chat/source.md"), lines[8])
      assert.equals("### 📝 一行要約", lines[10])
      assert.equals("- 決めた", lines[12])
      -- 末尾は空行: ユーザーが続きの指示をここに書く
      assert.equals("", lines[#lines])
    end)

    it("never contains a `## summary` heading", function()
      local body = Handoff.build_body("### x\n\n- y", "a.md")
      assert.is_nil(body:match("\n## summary"))
    end)
  end)

  describe("create_session", function()
    it("writes a chat file whose first message carries the summary", function()
      local chat_buffer = make_chat_buffer()
      local session, err = Handoff.create_session(chat_buffer, SUMMARY)

      assert.is_nil(err)
      assert.is_not_nil(session)
      local path = session:get_file_path()
      assert.equals(1, vim.fn.filereadable(path))

      local content = table.concat(vim.fn.readfile(path), "\n")
      local fm, body = Frontmatter.parse(content)

      assert.truthy(body:find(Timestamp.create_unsent_user_header(), 1, true))
      assert.truthy(body:find("- 認証まわりのリファクタ方針を決めた", 1, true))
      assert.truthy(body:find("- `auth.lua` のテストを書く", 1, true))
      assert.is_nil(body:find("## summary", 1, true))
      -- 前置きは元チャットの表示パスを指す
      assert.truthy(body:find(string.format(Handoff.LEAD_IN, fm.continued_from), 1, true))
    end)

    it("starts a fresh session instead of resuming the source", function()
      local chat_buffer = make_chat_buffer()
      local session = Handoff.create_session(chat_buffer, SUMMARY)

      assert.is_nil(session:get_session_id())
      local fm = Frontmatter.parse(table.concat(vim.fn.readfile(session:get_file_path()), "\n"))
      assert.is_true(fm.session_id == nil or fm.session_id == "~")
    end)

    it("inherits the source's settings but not its lineage", function()
      local chat_buffer = make_chat_buffer()
      local session = Handoff.create_session(chat_buffer, SUMMARY)
      local fm = Frontmatter.parse(table.concat(vim.fn.readfile(session:get_file_path()), "\n"))

      assert.equals("opus", fm.model)
      assert.equals("high", fm.effort)
      assert.equals("acceptEdits", fm.permission_mode)
      assert.same({ "Read", "Edit" }, fm.permissions_allow)
      assert.same({ "Bash" }, fm.permissions_deny)
      assert.equals("ja", fm.language)
      assert.equals(".vibing/worktrees/auth", fm.working_dir)
      assert.equals(".vibing/worktrees/auth", session:get_working_dir())

      assert.is_nil(fm.forked_from)
      assert.is_nil(fm.orchestrated_by)
      assert.is_not_nil(fm.continued_from)
    end)

    it("orders continued_from with the other lineage keys", function()
      local chat_buffer = make_chat_buffer()
      local session = Handoff.create_session(chat_buffer, SUMMARY)
      local lines = vim.fn.readfile(session:get_file_path())

      local continued_at, model_at
      for i, line in ipairs(lines) do
        if line:match("^continued_from:") then
          continued_at = i
        elseif line:match("^model:") then
          model_at = i
        end
      end
      assert.is_not_nil(continued_at)
      assert.is_true(continued_at < model_at)
    end)

    it("names the file after the source and never overwrites", function()
      local chat_buffer = make_chat_buffer({ file_path = save_dir .. "auth-refactor.md" })
      local first = Handoff.create_session(chat_buffer, SUMMARY)
      local second = Handoff.create_session(chat_buffer, SUMMARY)

      assert.equals(save_dir .. "auth-refactor-handoff-1.md", first:get_file_path())
      assert.equals(save_dir .. "auth-refactor-handoff-2.md", second:get_file_path())
    end)

    it("refuses an empty summary", function()
      local chat_buffer = make_chat_buffer()
      local session, err = Handoff.create_session(chat_buffer, "## summary\n")

      assert.is_nil(session)
      assert.equals("Summary is empty", err)
    end)

    it("refuses a buffer with no file", function()
      local session, err = Handoff.create_session({ buf = 1 }, SUMMARY)

      assert.is_nil(session)
      assert.is_not_nil(err)
    end)
  end)

  describe("execute", function()
    local summarize_calls

    local function stub_summarize(ok, summary)
      summarize_calls = 0
      package.loaded["vibing.application.chat.use_case"] = {
        generate_and_insert_summary = function(chat_buffer, opts)
          summarize_calls = summarize_calls + 1
          if ok then
            local SummaryInserter = require("vibing.presentation.chat.modules.summary_inserter")
            assert.is_true(SummaryInserter.insert_or_update(chat_buffer.buf, summary or SUMMARY))
          end
          opts.on_done(ok, ok and nil or "stubbed failure")
        end,
      }
    end

    it("hands the new session to on_done and saves the source with its summary", function()
      stub_summarize(true)
      local chat_buffer = make_chat_buffer()
      local got_session, got_err

      Handoff.execute(chat_buffer, {
        on_done = function(session, err)
          got_session, got_err = session, err
        end,
      })

      assert.is_nil(got_err)
      assert.is_not_nil(got_session)
      assert.equals(1, vim.fn.filereadable(got_session:get_file_path()))

      -- 元チャットにも `## summary` が残り、ディスクに保存されている
      local source = table.concat(vim.fn.readfile(chat_buffer.file_path), "\n")
      assert.truthy(source:find("## summary", 1, true))
    end)

    -- 要約の生成は会話全体を読ませる1リクエストで、引き継ぎで削りたいコストそのもの。
    -- 直前に `:VibingSummarize` を走らせたユーザーに二度払わせない。
    it("reuses an existing ## summary instead of generating one", function()
      stub_summarize(true, "## summary\n\n- 生成された要約")
      local chat_buffer = make_chat_buffer({
        body = table.concat({
          "",
          "# Vibing Chat",
          "",
          "## summary",
          "",
          "- 既にある要約",
          "",
          "---",
          "",
          "## 2025-01-01 00:00:00 User",
          "",
          "Hello",
          "",
        }, "\n"),
      })
      local got_session

      Handoff.execute(chat_buffer, {
        on_done = function(session)
          got_session = session
        end,
      })

      assert.equals(0, summarize_calls)
      assert.is_not_nil(got_session)
      local handoff = table.concat(vim.fn.readfile(got_session:get_file_path()), "\n")
      assert.truthy(handoff:find("- 既にある要約", 1, true))
      assert.is_nil(handoff:find("- 生成された要約", 1, true))
    end)

    -- 見出しだけで本文が無いセクションは `extract` が nil を返す。生成を飛ばすと
    -- 「Summary is empty」で引き継ぎごと落ちるので、ここは生成しなければならない。
    it("still generates when the existing summary section is empty", function()
      stub_summarize(true)
      local chat_buffer = make_chat_buffer({
        body = "\n# Vibing Chat\n\n## summary\n\n---\n\n## 2025-01-01 00:00:00 User\n\nHello\n",
      })
      local got_session

      Handoff.execute(chat_buffer, {
        on_done = function(session)
          got_session = session
        end,
      })

      assert.equals(1, summarize_calls)
      assert.is_not_nil(got_session)
    end)

    it("reports a failed summary without creating anything", function()
      stub_summarize(false)
      local chat_buffer = make_chat_buffer()
      local calls = {}

      Handoff.execute(chat_buffer, {
        on_done = function(session, err)
          table.insert(calls, { session = session, err = err })
        end,
      })

      assert.equals(1, #calls)
      assert.is_nil(calls[1].session)
      assert.equals("stubbed failure", calls[1].err)
      assert.same({}, vim.fn.glob(save_dir .. "*-handoff-*.md", false, true))
    end)

    it("reports an invalid buffer synchronously", function()
      local calls = 0
      Handoff.execute({ buf = -1 }, {
        on_done = function(session)
          calls = calls + 1
          assert.is_nil(session)
        end,
      })
      assert.equals(1, calls)
    end)
  end)
end)
