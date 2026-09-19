describe("set_file_title handler - streaming guard", function()
  local handler
  local title_generator
  local original_generate

  before_each(function()
    package.loaded["vibing.application.chat.handlers.set_file_title"] = nil
    handler = require("vibing.application.chat.handlers.set_file_title")
    title_generator = require("vibing.core.utils.title_generator")
    original_generate = title_generator.generate_from_conversation
  end)

  -- 差し替えの復帰は after_each で行う。it の本文末尾に置くと、assert が落ちたときに
  -- モンキーパッチが後続の spec に漏れて、1件の失敗が無関係な失敗の連鎖になる
  after_each(function()
    title_generator.generate_from_conversation = original_generate
    package.loaded["vibing.application.chat.handlers.set_file_title"] = nil
  end)

  it("returns false and skips title generation while the main response is streaming", function()
    local generate_called = false
    title_generator.generate_from_conversation = function()
      generate_called = true
    end

    local buf = vim.api.nvim_create_buf(false, true)
    local chat_buffer = {
      buf = buf,
      is_sending = function()
        return true
      end,
      extract_conversation = function()
        return { { role = "user", content = "hi" } }
      end,
    }

    local ok = handler({}, chat_buffer)

    assert.is_false(ok)
    assert.is_false(generate_called)
  end)

  it("proceeds to title generation when not sending", function()
    local generate_called = false
    title_generator.generate_from_conversation = function()
      generate_called = true
    end

    local buf = vim.api.nvim_create_buf(false, true)
    local chat_buffer = {
      buf = buf,
      is_sending = function()
        return false
      end,
      extract_conversation = function()
        return { { role = "user", content = "hi" } }
      end,
      get_session_id = function()
        return nil
      end,
    }

    handler({}, chat_buffer)

    assert.is_true(generate_called)
  end)

  it("hands the title generator no adapter, so a codex chat still uses the global default", function()
    require("vibing").setup({})
    -- チャット固有のアダプタ解決は `send_message._resolve_adapter` 経由だった。setup() は
    -- このモジュールを読み込まないので、「読み込まれていないこと」がその経路を通っていない
    -- 証拠になる。関数単位の spy と違い、send_message へ入るどの経路でも落ちる
    package.loaded["vibing.application.chat.send_message"] = nil

    local third_arg
    title_generator.generate_from_conversation = function(_, _, opts)
      third_arg = opts
    end

    local buf = vim.api.nvim_create_buf(false, true)
    local chat_buffer = {
      buf = buf,
      is_sending = function()
        return false
      end,
      extract_conversation = function()
        return { { role = "user", content = "hi" } }
      end,
      parse_frontmatter = function()
        return { agent = "codex" }
      end,
    }

    handler({}, chat_buffer)

    assert.is_nil(package.loaded["vibing.application.chat.send_message"])
    -- 第3引数は opts テーブルであってアダプタではない
    assert.is_nil(third_arg.name)
  end)

  it("falls back to a message-based name when title generation fails", function()
    local save_dir = vim.fn.tempname() .. "/vibing_title_fb"
    require("vibing").setup({ chat = { save_location_type = "custom", save_dir = save_dir } })
    vim.fn.mkdir(save_dir, "p")

    -- Simulate the real failure (e.g. "Prompt is too long"): the callback is
    -- invoked with an error. The handler must still name the file, not bail out.
    local original_generate = require("vibing.core.utils.title_generator").generate_from_conversation
    require("vibing.core.utils.title_generator").generate_from_conversation = function(_, cb)
      cb(nil, "Prompt is too long")
    end

    local buf = vim.api.nvim_create_buf(false, true)
    local chat_buffer = {
      buf = buf,
      file_path = nil,
      is_sending = function()
        return false
      end,
      extract_conversation = function()
        return { { role = "user", content = "Fix the login bug" } }
      end,
      get_session_id = function()
        return nil
      end,
      parse_frontmatter = function()
        return {}
      end,
    }

    local ok = handler({}, chat_buffer)
    assert.is_true(ok)

    -- The buffer is renamed from the first user message, not left unnamed.
    local name = vim.api.nvim_buf_get_name(buf)
    assert.is_not_nil(name:match("chat%-%d+%-Fix_the_login_bug%.md$"))

    require("vibing.core.utils.title_generator").generate_from_conversation = original_generate
    if vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
  end)
end)

describe("set_file_title handler - summary as input", function()
  local handler, title_generator, original_generate

  local function chat_buffer_with(lines)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    return {
      buf = buf,
      is_sending = function()
        return false
      end,
      extract_conversation = function()
        return { { role = "user", content = "hi" } }
      end,
      get_session_id = function()
        return nil
      end,
    }
  end

  before_each(function()
    package.loaded["vibing.application.chat.handlers.set_file_title"] = nil
    handler = require("vibing.application.chat.handlers.set_file_title")
    title_generator = require("vibing.core.utils.title_generator")
    original_generate = title_generator.generate_from_conversation
  end)

  after_each(function()
    title_generator.generate_from_conversation = original_generate
    package.loaded["vibing.application.chat.handlers.set_file_title"] = nil
  end)

  it("passes the buffer's `## summary` section to the title generator", function()
    local passed_opts
    title_generator.generate_from_conversation = function(_, _, opts)
      passed_opts = opts
    end

    handler({}, chat_buffer_with({
      "---",
      "vibing.nvim: true",
      "---",
      "# Vibing Chat",
      "",
      "## summary",
      "",
      "### 一行要約",
      "- タイトル生成の入力を summary 優先にした",
      "",
      "---",
      "## User",
      "hi",
    }))

    assert.is_truthy(passed_opts.summary:find("タイトル生成の入力を summary 優先にした", 1, true))
  end)

  it("passes no summary when the buffer has none, so the excerpt path stays the default", function()
    local passed_opts
    title_generator.generate_from_conversation = function(_, _, opts)
      passed_opts = opts
    end

    handler({}, chat_buffer_with({
      "---",
      "vibing.nvim: true",
      "---",
      "# Vibing Chat",
      "---",
      "## User",
      "hi",
    }))

    assert.is_table(passed_opts)
    assert.is_nil(passed_opts.summary)
  end)
end)

-- 改名は「名前を変える」であって「引っ越す」ではない。`--linked` は設定の保存先の外にある
-- チャット（別プロジェクトのもの）まで辿るので、保存先へ寄せる実装だと会話ファイルが物理的に
-- 移動し、移動元に残ったリンクは `RenameSync` の走査範囲の外なので誰も直さない。
describe("set_file_title handler - where the renamed file lands", function()
  local handler, title_generator, original_generate, tmpdir, synced_dir
  local notify = require("vibing.core.utils.notify")

  before_each(function()
    synced_dir = nil
    -- リンク同期は全走査を伴うので差し替える。ハンドラは `RenameSync` をモジュール先頭で
    -- 掴むので、**require より前に**入れ替えないと本物が走る
    package.loaded["vibing.application.link.rename_sync"] = {
      apply = function(_, _, save_dir)
        synced_dir = save_dir
      end,
    }
    package.loaded["vibing.application.chat.handlers.set_file_title"] = nil
    handler = require("vibing.application.chat.handlers.set_file_title")
    title_generator = require("vibing.core.utils.title_generator")
    original_generate = title_generator.generate_from_conversation
    tmpdir = vim.fn.tempname()
    vim.fn.mkdir(tmpdir, "p")
  end)

  after_each(function()
    title_generator.generate_from_conversation = original_generate
    package.loaded["vibing.application.chat.handlers.set_file_title"] = nil
    package.loaded["vibing.application.link.rename_sync"] = nil
    vim.fn.delete(tmpdir, "rf")
  end)

  ---@param name string
  ---@return table chat_buffer
  local function existing_chat(name)
    local path = tmpdir .. "/" .. name
    vim.fn.writefile({ "---", "vibing.nvim: true", "---", "# Vibing Chat", "## User", "hi" }, path)
    local buf = vim.fn.bufadd(path)
    vim.fn.bufload(buf)
    return {
      buf = buf,
      file_path = path,
      is_sending = function()
        return false
      end,
      extract_conversation = function()
        return { { role = "user", content = "hi" } }
      end,
      get_session_id = function()
        return nil
      end,
    }
  end

  it("renames an existing chat inside its own directory, not the configured save dir", function()
    title_generator.generate_from_conversation = function(_, callback)
      callback("renamed here")
    end

    local chat_buffer = existing_chat("chat-20260101-120000-abc-0001.md")
    local path = chat_buffer.file_path

    handler({}, chat_buffer)

    assert.equals(tmpdir, vim.fn.fnamemodify(chat_buffer.file_path, ":h"))
    assert.equals(0, vim.fn.filereadable(path))
    assert.equals(1, vim.fn.filereadable(chat_buffer.file_path))
    assert.equals(tmpdir, synced_dir)
  end)

  -- `quiet` は「新しい名前は呼び出し側が見せる」の意味。`--linked` の進捗フロートは木の行を
  -- 新しい名前に差し替えるので、同じ内容を通知でも流すと件数ぶん同じ行が積み上がる
  it("announces the new name by default, and holds its tongue when asked to", function()
    title_generator.generate_from_conversation = function(_, callback)
      callback("renamed here")
    end

    local said = {}
    local original_info = notify.info
    notify.info = function(message)
      table.insert(said, message)
    end

    handler({}, existing_chat("chat-20260101-120000-abc-0001.md"))
    local after_default = #said

    handler({}, existing_chat("chat-20260101-120000-abc-0002.md"), { quiet = true })

    notify.info = original_info

    assert.equals(1, after_default)
    assert.is_truthy(said[1]:find("Renamed to", 1, true))
    assert.equals(after_default, #said)
  end)
end)
