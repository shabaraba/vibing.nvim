local ProgrammaticSender = require("vibing.presentation.chat.modules.programmatic_sender")
local ChatBuffer = require("vibing.presentation.chat.buffer")
local view = require("vibing.presentation.chat.view")

describe("ProgrammaticSender.send", function()
  local original_get_chat_buffer
  local bufnr
  local fake

  before_each(function()
    original_get_chat_buffer = view.get_chat_buffer
    bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "---", "vibing.nvim: true", "---", "" })

    fake = { responding = false, sends = 0, result = true }
    view.get_chat_buffer = function(target)
      if target ~= bufnr then
        return nil
      end
      return {
        is_responding = function()
          return fake.responding
        end,
        send_message = function()
          fake.sends = fake.sends + 1
          return fake.result
        end,
      }
    end
  end)

  after_each(function()
    view.get_chat_buffer = original_get_chat_buffer
    if vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end
  end)

  ---@return number
  local function user_headers()
    local count = 0
    for _, line in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
      if line:match("User") then
        count = count + 1
      end
    end
    return count
  end

  ---@return string[]
  local function buffer_lines()
    return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  end

  it("writes the delivery header it was handed instead of a plain User section", function()
    ProgrammaticSender.send(bufnr, "done", nil, { kind = "Report", from = ".vibing/chat/worker.md" })

    local lines = buffer_lines()
    assert.is_true(
      vim.tbl_contains(lines, "## Report <!-- unsent from .vibing/chat/worker.md -->"),
      table.concat(lines, "\n")
    )
  end)

  it("fills the empty unsent section a finished turn left behind", function()
    -- ターンが終わるたび `add_user_section()` が空の未送信セクションを置く。人間はそこに
    -- 打ち込むが、配達はその下にもう1つ足していたので、配達されたターンの上に空の
    -- `## User` が毎回取り残されていた
    vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, { "## User <!-- unsent -->", "", "" })

    ProgrammaticSender.send(bufnr, "hello", nil, { kind = "Request" })

    local headers = vim.tbl_filter(function(line)
      return line:match("^## ")
    end, buffer_lines())
    assert.same({ "## Request <!-- unsent -->" }, headers)
  end)

  it("keeps a trailing section that still has something in it", function()
    -- 承認プロンプトや質問の選択肢は同じ未送信セクションに描かれる。空でないものを
    -- 落とすと、ユーザーが答えようとしていた選択肢が配達のたびに消える
    vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, { "## User <!-- unsent -->", "", "1. PostgreSQL", "" })

    ProgrammaticSender.send(bufnr, "hello", nil, { kind = "Request" })

    local lines = buffer_lines()
    assert.is_true(vim.tbl_contains(lines, "1. PostgreSQL"), table.concat(lines, "\n"))
  end)

  it("replaces a trailing section with something in it when asked to", function()
    -- 承認への代理応答（`approval_delegate`）だけがこれを渡す。そこでは承認プロンプトそのものが
    -- 「答える対象」なので、残すと答え終わったプロンプトがバッファに永久に居座る
    vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, {
      "## User <!-- unsent -->",
      "",
      "⚠️  Tool approval required",
      "",
      "1. allow_once - Allow this execution only",
      "",
    })

    ProgrammaticSender.send(bufnr, "1. allow_once - Allow this execution only", nil, {
      kind = "Request",
      from = ".vibing/chat/orchestrator.md",
    }, { replace_unsent = true })

    local lines = buffer_lines()
    assert.is_false(vim.tbl_contains(lines, "⚠️  Tool approval required"), table.concat(lines, "\n"))

    local headers = vim.tbl_filter(function(line)
      return line:match("^## ")
    end, lines)
    assert.same({ "## Request <!-- unsent from .vibing/chat/orchestrator.md -->" }, headers)
  end)

  it("leaves an already-committed trailing section alone even with replace_unsent", function()
    -- 「未送信ヘッダーが見つかるまで遡る」実装だと、送信済みセクションを飛び越えて上のほうの
    -- 未送信セクションを消しうる。末尾から最初に当たったヘッダーだけを見る
    vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, {
      "## User <!-- 2026-09-03 10:00:00 -->",
      "",
      "already sent",
      "",
    })

    ProgrammaticSender.send(bufnr, "hello", nil, { kind = "Request" }, { replace_unsent = true })

    local lines = buffer_lines()
    assert.is_true(vim.tbl_contains(lines, "already sent"), table.concat(lines, "\n"))
  end)

  it("refuses a chat that is already responding, before touching the buffer", function()
    -- 追加してから巻き戻すのではなく追加する前に断る。`ChatBuffer:send_message()` は
    -- 応答中なら黙って return するので、先に append すると送られない `## User` が残り、
    -- 次にユーザーが<CR>したときの本文に化ける
    fake.responding = true
    local before = user_headers()

    assert.has_error(function()
      ProgrammaticSender.send(bufnr, "hello")
    end)
    assert.equals(0, fake.sends)
    assert.equals(before, user_headers())
  end)

  it("reports success only when the chat actually took the message", function()
    assert.is_true(ProgrammaticSender.send(bufnr, "hello").success)

    fake.result = false
    assert.is_false(ProgrammaticSender.send(bufnr, "hello").success)
  end)

  it("rejects an empty message and a non-chat buffer", function()
    assert.has_error(function()
      ProgrammaticSender.send(bufnr, "   ")
    end)
    assert.has_error(function()
      ProgrammaticSender.send(bufnr + 9999, "hello")
    end)
  end)
end)

describe("ChatBuffer:add_user_section", function()
  it("does not fire VibingResponseDone on its own", function()
    -- 完了イベントは send_message() のコールバックラッパー側にある。このメソッド本体に
    -- 置くと、スラッシュコマンド経路（AIターンが1回も走っていない）からも完了が飛ぶ
    local bufnr = vim.api.nvim_create_buf(false, true)
    local chat = setmetatable({ buf = bufnr, win = nil, _chunk_buffer = "" }, ChatBuffer)

    local fired = 0
    local group = vim.api.nvim_create_augroup("VibingCompletionNotifierSpec", { clear = true })
    vim.api.nvim_create_autocmd("User", {
      group = group,
      pattern = "VibingResponseDone",
      callback = function()
        fired = fired + 1
      end,
    })

    chat:add_user_section()

    vim.api.nvim_del_augroup_by_id(group)
    vim.api.nvim_buf_delete(bufnr, { force = true })

    assert.equals(0, fired)
  end)
end)
