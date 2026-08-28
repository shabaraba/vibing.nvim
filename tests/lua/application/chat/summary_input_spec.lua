-- `:VibingSummarize` の入力側の上限を固定する。
--
-- 発端は 43通 / 261,741文字のチャットで要約が一度も通らなかったこと。当時の上限は
-- `MAX_MESSAGES_FOR_SUMMARY`（件数）だけで、43通は上限に掛からず全文がそのまま1プロンプトに
-- なった（うち1通で76,026バイト）。実測では 110,497 トークンを消費して応答自体は返るが、
-- モデルが `prompts/chat_summary.md` の出力形式を守れず先頭行が `## summary` にならないため、
-- `summary_inserter` が応答を丸ごと捨てて "Invalid summary format" だけが残る。
--
-- つまりここで守っているのは「送る量」であって、要約の文面ではない。件数の上限だけでは
-- この症状を防げないことがこのファイルの主題なので、文字数の主張を件数の主張に
-- 置き換えないこと。

local use_case = require("vibing.application.chat.use_case")

-- git 管理外の空ディレクトリ。cwd を渡さないと、リポジトリ URL の解決がテスト実行環境の
-- 本物の origin を読みに行く。このファイルの主題（送る量）とは関係のない副作用になる
local scratch_dir = vim.fn.tempname()
vim.fn.mkdir(scratch_dir, "p")

---@param conversation table[]
---@return string
local function build_prompt(conversation)
  return assert(use_case._build_summary_prompt(conversation, scratch_dir))
end

---@param n integer
---@param char string
---@return string
local function filler(n, char)
  return string.rep(char or "あ", n)
end

describe("summary prompt input", function()
  it("strips tool transcript noise before sending", function()
    local conversation = {
      { role = "user", content = "レイヤー構成を整理して" },
      {
        role = "assistant",
        content = table.concat({
          "分類の方針を決めます。",
          "⏺ Read(lua/vibing/init.lua)",
          "  ⎿ local M = {}",
          "     return M",
          "handler → service → repository の一方向にします。",
        }, "\n"),
      },
    }

    local prompt = build_prompt(conversation)

    assert.is_truthy(prompt:find("handler → service → repository", 1, true))
    assert.is_nil(prompt:find("Read(lua/vibing/init.lua)", 1, true), "tool header reached the prompt")
    assert.is_nil(prompt:find("local M = {}", 1, true), "tool result reached the prompt")
  end)

  it("elides an oversized message from the middle, keeping both ends", function()
    local content = "決定の前置き" .. filler(20000) .. "最終的にrepositoryへ寄せる"
    local prompt = build_prompt({
      { role = "assistant", content = content },
    })

    assert.is_truthy(prompt:find("決定の前置き", 1, true), "the head of the message was dropped")
    assert.is_truthy(prompt:find("最終的にrepositoryへ寄せる", 1, true), "the tail of the message was dropped")
    assert.is_true(vim.fn.strchars(prompt) < vim.fn.strchars(content), "nothing was elided")
  end)

  it("bounds the whole prompt for a conversation the size of the one that broke it", function()
    -- 実測ベース: 43通、assistant 1通あたり最大 76,026 バイト、合計 261,741 文字。
    local conversation = { { role = "user", content = "レイヤー構成規約を策定したい" } }
    for i = 1, 21 do
      conversation[#conversation + 1] = { role = "assistant", content = "応答" .. i .. filler(12000) }
      conversation[#conversation + 1] = { role = "user", content = "続けて" .. i }
    end

    local prompt = build_prompt(conversation)

    assert.is_true(
      vim.fn.strchars(prompt) <= use_case.MAX_TOTAL_CHARS + 10000,
      ("prompt was %d chars"):format(vim.fn.strchars(prompt))
    )
  end)

  it("keeps the opening request when older messages are dropped for budget", function()
    local conversation = { { role = "user", content = "最初の依頼: レイヤー構成規約を策定したい" } }
    for i = 1, 40 do
      conversation[#conversation + 1] = { role = "assistant", content = filler(8000) }
    end
    conversation[#conversation + 1] = { role = "user", content = "最後の依頼: PRを出して" }

    local prompt = build_prompt(conversation)

    assert.is_truthy(prompt:find("最初の依頼", 1, true), "the opening request was dropped")
    assert.is_truthy(prompt:find("最後の依頼", 1, true), "the newest message was dropped")
  end)

  it("says so in the prompt when messages were dropped", function()
    local conversation = {}
    for i = 1, 60 do
      conversation[#conversation + 1] = { role = "user", content = "依頼" .. i .. filler(4000) }
    end

    local prompt = build_prompt(conversation)

    assert.is_truthy(prompt:find(use_case.OMISSION_MARKER, 1, true), "the elision was silent")
  end)

  it("leaves a short conversation untouched", function()
    local prompt = build_prompt({
      { role = "user", content = "これは短い依頼" },
      { role = "assistant", content = "これは短い応答" },
    })

    assert.is_truthy(prompt:find('<message role="user">\nこれは短い依頼\n</message>', 1, true))
    assert.is_truthy(prompt:find('<message role="assistant">\nこれは短い応答\n</message>', 1, true))
    assert.is_nil(prompt:find(use_case.OMISSION_MARKER, 1, true), "a short conversation was elided")
  end)

  it("falls back to the raw text when cleaning removes everything", function()
    -- 応答がフェンス済みコードブロックだけ、という会話は実在する。クリーニングは
    -- コードブロックを丸ごと落とすので、そのまま渡すと空の <conversation> が飛ぶ。
    local conversation = {
      { role = "assistant", content = "```lua\nlocal M = {}\nreturn M\n```" },
    }

    local prompt = build_prompt(conversation)

    assert.is_truthy(prompt:find("local M = {}", 1, true), "the only content in the chat was dropped")
  end)
end)

describe("summary call options", function()
  local captured_opts

  before_each(function()
    captured_opts = nil
    package.loaded["vibing"] = {
      get_config = function()
        return { permissions = { mode = "acceptEdits", allow = { "Read" }, deny = { "Bash" } } }
      end,
      get_adapter = function()
        return {
          stream = function(_, _prompt, opts, _on_chunk, on_done)
            captured_opts = opts
            on_done({ error = "stubbed" })
          end,
        }
      end,
    }
  end)

  after_each(function()
    package.loaded["vibing"] = nil
  end)

  it("marks the call lightweight, like the /summarize handler does", function()
    -- 非 lightweight だと frontmatter の model（opus 等）に加えて全ツール・CLAUDE.md・
    -- ユーザーの MCP サーバー定義・開いているバッファの context prefix まで載る。要約には
    -- どれも要らず、コンテキストだけを食う。
    use_case.generate_and_insert_summary({
      buf = vim.api.nvim_create_buf(false, true),
      is_sending = function()
        return false
      end,
      extract_conversation = function()
        return { { role = "user", content = "hi" } }
      end,
      -- git 管理外の空ディレクトリを返す。nil だとリポジトリ URL の解決がテスト実行環境の
      -- 本物の origin を読みに行き、このテストの主題（lightweight フラグ）と関係のない
      -- 副作用になる
      get_cwd = function()
        local dir = vim.fn.tempname()
        vim.fn.mkdir(dir, "p")
        return dir
      end,
    })

    assert.is_true(captured_opts.lightweight)
  end)
end)
