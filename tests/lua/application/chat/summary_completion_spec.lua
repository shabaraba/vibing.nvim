-- `generate_and_insert_summary` の完了コールバックの契約を固定する。
--
-- 主題は「必ず1回だけ呼ばれる」こと。summary → title は本質的に順序依存で（タイトル生成は
-- バッファの `## summary` を入力に使う）、連鎖する呼び出し側は完了通知だけを頼りに待つ。
-- 呼ばれない脱出経路が1つでもあると、そこでは「まだ来ていない」と「もう来ない」が
-- 区別できず、呼び出し側はバッファ内容のポーリングに逆戻りする（#615）。
--
-- したがって以下の主張は「同期的な失敗でも呼ぶ」ことに寄せてある。非同期パスだけを
-- 確かめるテストに置き換えないこと。

local use_case = require("vibing.application.chat.use_case")

---@param opts? {is_sending?: boolean, conversation?: table[]}
---@return table
local function chat_buffer(opts)
  opts = opts or {}
  return {
    buf = vim.api.nvim_create_buf(false, true),
    is_sending = function()
      return opts.is_sending or false
    end,
    extract_conversation = function()
      return opts.conversation or { { role = "user", content = "レイヤー構成を整理して" } }
    end,
  }
end

---呼ばれた回数まで数えたいので、記録先のテーブルとコールバックを組で返す。
---@return table calls
---@return fun(ok: boolean, err: string?) on_done
local function recorder()
  local calls = {}
  return calls, function(ok, err)
    calls[#calls + 1] = { ok = ok, err = err }
  end
end

---@param response table|nil アダプターが on_done に渡す応答
local function stub_vibing(response)
  package.loaded["vibing"] = {
    get_config = function()
      return { permissions = { mode = "acceptEdits", allow = { "Read" }, deny = {} } }
    end,
    get_adapter = function()
      return {
        stream = function(_, _prompt, _opts, _on_chunk, on_done)
          on_done(response)
        end,
      }
    end,
  }
end

---プロンプトの読み込みをスタブする。
---
---本物の `PromptLoader` は runtimepath から `vibing.nvim` で終わるディレクトリを探すため、
---worktree（`.vibing/worktrees/<branch>`）でスイートを回すと必ず失敗する。ここの主題は
---コールバックの契約であってプロンプトの中身ではないので、その依存ごと外す。
---@param err string? 読み込み失敗を再現する場合のエラー文言
local function stub_prompt_loader(err)
  package.loaded["vibing.core.utils.prompt_loader"] = {
    load = function()
      if err then
        return nil, err
      end
      return "<conversation>stubbed</conversation>"
    end,
  }
end

describe("generate_and_insert_summary on_done", function()
  before_each(function()
    stub_prompt_loader()
  end)

  after_each(function()
    package.loaded["vibing"] = nil
    package.loaded["vibing.core.utils.prompt_loader"] = nil
  end)

  it("reports failure when a response is streaming", function()
    local calls, on_done = recorder()

    use_case.generate_and_insert_summary(chat_buffer({ is_sending = true }), { on_done = on_done })

    assert.equals(1, #calls)
    assert.is_false(calls[1].ok)
    assert.is_truthy(calls[1].err)
  end)

  it("reports failure when there is nothing to summarize", function()
    local calls, on_done = recorder()

    use_case.generate_and_insert_summary(chat_buffer({ conversation = {} }), { on_done = on_done })

    assert.equals(1, #calls)
    assert.is_false(calls[1].ok)
  end)

  it("reports failure when no adapter is configured", function()
    package.loaded["vibing"] = {
      get_config = function()
        return { permissions = { mode = "acceptEdits", allow = {}, deny = {} } }
      end,
      get_adapter = function()
        return nil
      end,
    }
    local calls, on_done = recorder()

    use_case.generate_and_insert_summary(chat_buffer(), { on_done = on_done })

    assert.equals(1, #calls)
    assert.is_false(calls[1].ok)
  end)

  it("reports failure when the prompt cannot be loaded", function()
    stub_vibing({ content = "## summary\n\n- 決めたこと" })
    stub_prompt_loader("Could not find vibing.nvim plugin directory")
    local calls, on_done = recorder()

    use_case.generate_and_insert_summary(chat_buffer(), { on_done = on_done })

    assert.equals(1, #calls)
    assert.is_false(calls[1].ok)
    assert.is_truthy(calls[1].err:find("plugin directory", 1, true))
  end)

  it("passes the adapter's error through", function()
    stub_vibing({ error = "usage limit reached" })
    local calls, on_done = recorder()

    use_case.generate_and_insert_summary(chat_buffer(), { on_done = on_done })

    assert.equals(1, #calls)
    assert.is_false(calls[1].ok)
    assert.is_truthy(calls[1].err:find("usage limit reached", 1, true))
  end)

  it("reports failure when the summary cannot be inserted", function()
    -- 応答は返っているが `## summary` で始まらないケース。挿入されていないので、
    -- ここで ok=true を返すとタイトル生成が summary 抜きで走ってしまう。
    stub_vibing({ content = "Here is a summary of the conversation." })
    local calls, on_done = recorder()

    use_case.generate_and_insert_summary(chat_buffer(), { on_done = on_done })

    assert.equals(1, #calls)
    assert.is_false(calls[1].ok)
  end)

  it("reports success once the summary is in the buffer", function()
    stub_vibing({ content = "## summary\n\n- 決めたこと" })
    local buffer = chat_buffer()
    vim.api.nvim_buf_set_lines(buffer.buf, 0, -1, false, {
      "---",
      "vibing.nvim: true",
      "---",
      "",
      "# Vibing Chat",
      "",
      "---",
      "",
      "## User",
      "レイヤー構成を整理して",
    })
    local calls, on_done = recorder()

    use_case.generate_and_insert_summary(buffer, { on_done = on_done })

    assert.equals(1, #calls)
    assert.is_true(calls[1].ok)
    assert.is_nil(calls[1].err)

    local SummaryInserter = require("vibing.presentation.chat.modules.summary_inserter")
    assert.is_truthy(SummaryInserter.extract(buffer.buf))
  end)

  it("still works without an on_done callback", function()
    stub_vibing({ content = "## summary\n\n- 決めたこと" })

    assert.has_no.errors(function()
      use_case.generate_and_insert_summary(chat_buffer())
    end)
  end)
end)
