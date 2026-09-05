--- 代理承認を、本物の `ChatBuffer` で端から端まで通す統合spec。
---
--- `approval_delegate_spec.lua` は `ProgrammaticSender.send` を差し替えて「何を書こうとしたか」
--- だけを見る。つまりこの機能の**後半** — 書いた行を `ChatBuffer:send_message()` が承認応答と
--- して読み、`update_session_permissions` を走らせ、`_pending_approval` を捨て、CLIに渡す本文を
--- 再試行文に差し替える — は、そちらでは1行も実行されない。
---
--- この機能の設計は「承認の意味を自前で持たず、人間の `<CR>` と同じ経路に流す」ことなので、
--- 検証すべきものはまさにその接続部にある。書く側と読む側が食い違えば、代理応答は黙って
--- ただのユーザーメッセージになり、承認は消費されないままワーカーが再試行してまた止まる —
--- エラーはどこにも出ない。だからここでは本物のバッファに本物の承認プロンプトを描かせ、
--- 止めるのは `SendMessage.execute`（ここから先は本物のCLIターン）だけにする。
local ApprovalDelegate = require("vibing.application.chat.approval_delegate")
local Config = require("vibing.config")
local vibing = require("vibing")
local view = require("vibing.presentation.chat.view")
local CreateChat = require("vibing.application.chat.use_cases.create_chat")
local SendMessage = require("vibing.application.chat.send_message")

-- `rpc/handlers/permission.lua` の APPROVAL_OPTIONS そのもの
local OPTIONS = {
  { value = "allow_once", label = "allow_once - Allow this execution only" },
  { value = "deny_once", label = "deny_once - Deny this execution only" },
  { value = "allow_for_session", label = "allow_for_session - Allow for this session" },
  { value = "deny_for_session", label = "deny_for_session - Deny for this session" },
}

describe("delegated approval, end to end", function()
  local originals = {}
  local save_dir
  local chats
  local requests

  ---@param enabled boolean
  local function configure(enabled)
    local cfg = vim.tbl_deep_extend("force", vim.deepcopy(Config.defaults), {
      chat = { save_location_type = "custom", save_dir = save_dir },
      agent = { orchestration = { delegated_approval = enabled } },
    })
    Config.get = function()
      return cfg
    end
    vibing.get_config = function()
      return cfg
    end
  end

  ---@return Vibing.ChatBuffer
  local function open_chat()
    local chat_buf = view.render(CreateChat.execute({}), "back", { background = true })
    table.insert(chats, chat_buf)
    return chat_buf
  end

  ---@param chat_buf Vibing.ChatBuffer
  ---@return string
  local function buffer_text(chat_buf)
    return table.concat(vim.api.nvim_buf_get_lines(chat_buf.buf, 0, -1, false), "\n")
  end

  ---承認待ちで止まったワーカーを1つ作る（`permission.lua` がやるのと同じ2手）
  ---@return Vibing.ChatBuffer
  local function blocked_worker()
    local worker = open_chat()
    worker:insert_approval_request("Bash", { command = "npm install" }, OPTIONS, "req-1")
    worker:add_user_section()
    return worker
  end

  before_each(function()
    originals.config_get = Config.get
    originals.get_config = vibing.get_config
    originals.get_adapter = vibing.get_adapter
    originals.execute = SendMessage.execute

    save_dir = vim.fn.tempname()
    vim.fn.mkdir(save_dir, "p")
    chats = {}
    requests = {}
    configure(true)

    vibing.get_adapter = function()
      return { name = "fake" }
    end
    -- ここから先は本物のCLIターン。何が送られようとしたかだけ読む
    SendMessage.execute = function(_, _, message)
      table.insert(requests, message)
    end
  end)

  after_each(function()
    Config.get = originals.config_get
    vibing.get_config = originals.get_config
    vibing.get_adapter = originals.get_adapter
    SendMessage.execute = originals.execute

    for _, chat_buf in ipairs(chats) do
      if vim.api.nvim_buf_is_valid(chat_buf.buf) then
        vim.api.nvim_buf_delete(chat_buf.buf, { force = true })
      end
    end
    vim.fn.delete(save_dir, "rf")
  end)

  it("consumes the approval and restarts the worker with the retry instruction", function()
    local orchestrator, worker = open_chat(), blocked_worker()
    assert.equals("waiting_approval", worker:get_stop_reason())

    ApprovalDelegate.answer({ bufnr = worker.buf, action = "allow_once", from_bufnr = orchestrator.buf })

    -- 承認が消費されたことの3つの現れ。どれか1つでも欠けると、ワーカーは同じ壁にまた当たる
    assert.is_nil(worker:get_pending_approval(), "the prompt must be marked consumed")
    assert.is_true(vim.tbl_contains(worker:get_session_allow(), "Bash:once"), "the grant must be recorded")
    assert.equals(1, #requests)
    assert.is_truthy(requests[1]:match("^I approved the Bash tool"), requests[1])
    -- 入力の要約まで渡すのは、モデルに同じ操作をやり直させるため
    assert.is_truthy(requests[1]:match("npm install"), requests[1])
  end)

  it("replaces the prompt in the transcript with a section naming who answered", function()
    local orchestrator, worker = open_chat(), blocked_worker()
    assert.is_truthy(buffer_text(worker):match("Tool approval required"))

    ApprovalDelegate.answer({ bufnr = worker.buf, action = "allow_once", from_bufnr = orchestrator.buf })

    local text = buffer_text(worker)
    -- 残すと、答え終わったプロンプトが以後の `extract_conversation` に毎回乗る
    assert.is_nil(text:match("Tool approval required"), text)
    assert.is_truthy(text:match("## Request <!%-%- %d%d%d%d%-%d%d%-%d%d "), text)
    assert.is_truthy(text:match("1%. allow_once %- Allow this execution only"), text)
  end)

  it("records a denial as a denial, and tells the worker to take another route", function()
    local orchestrator, worker = open_chat(), blocked_worker()

    ApprovalDelegate.answer({ bufnr = worker.buf, action = "deny_for_session", from_bufnr = orchestrator.buf })

    assert.is_true(vim.tbl_contains(worker:get_session_deny(), "Bash"))
    assert.is_truthy(requests[1]:match("^I denied the Bash tool"), requests[1])
  end)

  it("leaves the prompt untouched when the feature is off", function()
    configure(false)
    local orchestrator, worker = open_chat(), blocked_worker()

    assert.has_error(function()
      ApprovalDelegate.answer({ bufnr = worker.buf, action = "allow_once", from_bufnr = orchestrator.buf })
    end)

    -- 断るだけでなく、ユーザーが答えられる状態のまま残っていること
    assert.is_truthy(worker:get_pending_approval())
    assert.equals("waiting_approval", worker:get_stop_reason())
    assert.is_truthy(buffer_text(worker):match("Tool approval required"))
    assert.equals(0, #requests)
  end)

  it("refuses a second answer to a prompt that was already consumed", function()
    local orchestrator, worker = open_chat(), blocked_worker()

    ApprovalDelegate.answer({ bufnr = worker.buf, action = "allow_once", from_bufnr = orchestrator.buf })
    -- 1回目の応答でワーカーは新しいターンに入っている。`SendMessage.execute` を差し替えて
    -- いるので `_is_sending` はそのまま立っており、2回目は「応答中」で弾かれる。承認が
    -- 消費済みであることも同じく理由になる — どちらでも通ってはいけない
    assert.has_error(function()
      ApprovalDelegate.answer({ bufnr = worker.buf, action = "deny_once", from_bufnr = orchestrator.buf })
    end)

    assert.equals(1, #requests)
  end)
end)
