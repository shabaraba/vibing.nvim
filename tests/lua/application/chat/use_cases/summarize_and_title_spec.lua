-- `--linked` の逐次実行を固定する。
--
-- 押さえたいのは3つ: リンク先は起点の**あと**に、1件ずつ、そして1件の失敗で止まらないこと。
-- 並行に投げる実装に戻すと、1コマンドでリンク網ぶんのCLIプロセスが同時に立ち、改名が
-- 書き換えるリンク先の frontmatter への書き込みも重なる。

local use_case = require("vibing.application.chat.use_cases.summarize_and_title")

describe("summarize_and_title", function()
  local calls
  local summary_results
  local origin
  local linked
  local open_failures
  local save_failures

  ---@param name string
  ---@return table
  local function fake_chat(name)
    return { name = name, file_path = "/chats/" .. name .. ".md", buf = name }
  end

  before_each(function()
    calls = {}
    summary_results = {}
    open_failures = {}
    save_failures = {}
    origin = fake_chat("origin")
    linked = {}

    package.loaded["vibing.presentation.chat.modules.file_manager"] = {
      save_buffer = function(buf)
        table.insert(calls, { op = "save", name = buf })
        if save_failures[buf] then
          return false, "stubbed write failure"
        end
        return true, nil
      end,
    }

    package.loaded["vibing.application.chat.linked_chats"] = {
      collect = function(file_path, bufnr)
        table.insert(calls, { op = "collect", path = file_path, bufnr = bufnr })
        return linked
      end,
    }

    package.loaded["vibing.application.chat.chat_locator"] = {
      open = function(path)
        if open_failures[path] then
          error("no file at " .. path)
        end
        return path
      end,
    }

    package.loaded["vibing.presentation.chat.view"] = {
      get_chat_buffer = function(bufnr)
        return fake_chat(vim.fn.fnamemodify(bufnr, ":t:r"))
      end,
    }

    package.loaded["vibing.application.chat.use_case"] = {
      generate_and_insert_summary = function(chat_buffer, opts)
        table.insert(calls, { op = "summary", name = chat_buffer.name })
        local ok = summary_results[chat_buffer.name]
        if ok == nil then
          ok = true
        end
        opts.on_done(ok)
      end,
    }

    package.loaded["vibing.application.chat.handlers.set_file_title"] = function(_, chat_buffer, opts)
      table.insert(calls, { op = "title", name = chat_buffer.name })
      opts.on_done(true)
      return true
    end
  end)

  after_each(function()
    package.loaded["vibing.presentation.chat.modules.file_manager"] = nil
    package.loaded["vibing.application.chat.linked_chats"] = nil
    package.loaded["vibing.application.chat.chat_locator"] = nil
    package.loaded["vibing.presentation.chat.view"] = nil
    package.loaded["vibing.application.chat.use_case"] = nil
    package.loaded["vibing.application.chat.handlers.set_file_title"] = nil
  end)

  ---@return string[] "op:name" の並び（保存は `saves()` で別に見る）
  local function trace()
    local out = {}
    for _, call in ipairs(calls) do
      if call.op ~= "save" then
        table.insert(out, call.op .. (call.name and (":" .. call.name) or ""))
      end
    end
    return out
  end

  ---@return string[] 保存されたバッファの並び
  local function saves()
    local out = {}
    for _, call in ipairs(calls) do
      if call.op == "save" then
        table.insert(out, call.name)
      end
    end
    return out
  end

  it("touches nothing but the origin without the flag", function()
    linked = { { path = "/chats/worker.md", abs = "/chats/worker.md" } }

    use_case.run(origin, { summarize = true, with_title = true, linked = false })

    assert.same({ "summary:origin", "title:origin" }, trace())
  end)

  it("applies the same steps to every linked chat, after the origin", function()
    linked = {
      { path = "/chats/worker-a.md", abs = "/chats/worker-a.md" },
      { path = "/chats/worker-b.md", abs = "/chats/worker-b.md" },
    }

    use_case.run(origin, { summarize = true, with_title = true, linked = true })

    assert.same({
      "collect",
      "summary:origin",
      "title:origin",
      "summary:worker-a",
      "title:worker-a",
      "summary:worker-b",
      "title:worker-b",
    }, trace())
  end)

  it("collects the link set before the origin is renamed", function()
    -- 改名はリンク先の frontmatter を書き換える。走査を起点の処理より後ろに置くと、
    -- リンクがどちらの名前を指しているかに結果が左右される
    linked = { { path = "/chats/worker.md", abs = "/chats/worker.md" } }

    use_case.run(origin, { summarize = false, with_title = true, linked = true })

    assert.equals("collect", calls[1].op)
    assert.equals(origin.file_path, calls[1].path)
    assert.same({ "collect", "title:origin", "title:worker" }, trace())
  end)

  it("keeps going when one chat fails", function()
    linked = {
      { path = "/chats/worker-a.md", abs = "/chats/worker-a.md" },
      { path = "/chats/worker-b.md", abs = "/chats/worker-b.md" },
    }
    summary_results["worker-a"] = false

    use_case.run(origin, { summarize = true, with_title = true, linked = true })

    -- worker-a は要約に失敗したのでタイトル生成へ進まず、worker-b はそのまま処理される
    assert.same({
      "collect",
      "summary:origin",
      "title:origin",
      "summary:worker-a",
      "summary:worker-b",
      "title:worker-b",
    }, trace())
  end)

  it("keeps going when the origin itself fails", function()
    -- 「要約する会話が無い」はそのチャット固有の事情で、リンク先には当てはまらない
    linked = { { path = "/chats/worker.md", abs = "/chats/worker.md" } }
    summary_results["origin"] = false

    use_case.run(origin, { summarize = true, with_title = true, linked = true })

    assert.same({ "collect", "summary:origin", "summary:worker", "title:worker" }, trace())
  end)

  it("saves every linked chat it changed, but not the origin", function()
    -- 要約の挿入はバッファを書き換えるだけ。リンク先は背景で開いたバッファなので、保存しないと
    -- 「更新した」と報告したファイルの中身が変わっておらず、`:qa` も modified で止まる。
    -- 起点はユーザーが見ているバッファなので、単発の `:VibingSummarize` と同じく触らない
    linked = {
      { path = "/chats/worker-a.md", abs = "/chats/worker-a.md" },
      { path = "/chats/worker-b.md", abs = "/chats/worker-b.md" },
    }

    use_case.run(origin, { summarize = true, with_title = false, linked = true })

    assert.same({ "worker-a", "worker-b" }, saves())
  end)

  it("does not save a chat whose summary failed", function()
    linked = { { path = "/chats/worker.md", abs = "/chats/worker.md" } }
    summary_results["worker"] = false

    use_case.run(origin, { summarize = true, with_title = false, linked = true })

    assert.same({}, saves())
  end)

  it("counts a chat it could not save as failed, and keeps going", function()
    linked = {
      { path = "/chats/worker-a.md", abs = "/chats/worker-a.md" },
      { path = "/chats/worker-b.md", abs = "/chats/worker-b.md" },
    }
    save_failures["worker-a"] = true

    use_case.run(origin, { summarize = true, with_title = false, linked = true })

    assert.same({ "collect", "summary:origin", "summary:worker-a", "summary:worker-b" }, trace())
    assert.same({ "worker-a", "worker-b" }, saves())
  end)

  it("skips a chat it cannot open and processes the rest", function()
    linked = {
      { path = "/chats/gone.md", abs = "/chats/gone.md" },
      { path = "/chats/worker.md", abs = "/chats/worker.md" },
    }
    open_failures["/chats/gone.md"] = true

    use_case.run(origin, { summarize = true, with_title = true, linked = true })

    assert.same({ "collect", "summary:origin", "title:origin", "summary:worker", "title:worker" }, trace())
  end)
end)
