--- `approval_delegate` — オーケストレーターがワーカーの承認プロンプトに代理で答える経路。
---
--- ここで固定したいのは3つ。既定で**断る**こと（承認ゲートを外せる状態は opt-in であって、
--- 有効化を忘れた設定で黙って通ってはいけない）、答えがバッファに書く行が
--- `approval_parser` の読む形と一字一句合うこと、そして代理応答が承認プロンプトのセクションを
--- 置き換えること。
---
--- 2つ目が肝心で、この機能は「承認の意味」を自前で持たない設計になっている
--- （選択肢の行を書いて `ChatBuffer:send_message()` に読ませるだけ）。その代わり、書く側と
--- 読む側が食い違った瞬間に代理応答は黙って**ただのユーザーメッセージ**になり、承認は
--- 消費されないままワーカーが再試行してまた止まる。片方だけを直しても気づけないので、
--- 両方をこのファイルで突き合わせる。
local ApprovalDelegate = require("vibing.application.chat.approval_delegate")
local ApprovalParser = require("vibing.presentation.chat.modules.approval_parser")
local ProgrammaticSender = require("vibing.presentation.chat.modules.programmatic_sender")
local OrchestrationLink = require("vibing.application.chat.orchestration_link")
local Notifier = require("vibing.application.chat.completion_notifier")
local Config = require("vibing.config")
local view = require("vibing.presentation.chat.view")

-- `rpc/handlers/permission.lua` の APPROVAL_OPTIONS と同じ形。ハンドラから渡ってくるものを
-- そのまま模す
local OPTIONS = {
  { value = "allow_once", label = "allow_once - Allow this execution only" },
  { value = "deny_once", label = "deny_once - Deny this execution only" },
  { value = "allow_for_session", label = "allow_for_session - Allow for this session" },
  { value = "deny_for_session", label = "deny_for_session - Deny for this session" },
}

describe("ApprovalDelegate", function()
  local originals = {}
  local worker, orchestrator
  local sends
  local pending
  local stop_reason

  ---@param enabled boolean
  local function configure(enabled)
    local cfg = vim.tbl_deep_extend("force", vim.deepcopy(Config.defaults), {
      agent = { orchestration = { delegated_approval = enabled } },
    })
    Config.get = function()
      return cfg
    end
  end

  before_each(function()
    originals.config_get = Config.get
    originals.get_chat_buffer = view.get_chat_buffer
    originals.send = ProgrammaticSender.send
    originals.validate = ProgrammaticSender.validate
    originals.link_or_warn = OrchestrationLink.link_or_warn
    originals.direction = OrchestrationLink.direction
    originals.on_sent = Notifier.on_sent

    worker = vim.api.nvim_create_buf(false, true)
    orchestrator = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(orchestrator, vim.fn.tempname() .. "-orchestrator.md")

    sends = {}
    pending = { tool = "Bash", input = { command = "npm install" }, options = OPTIONS }
    stop_reason = "waiting_approval"

    configure(true)

    view.get_chat_buffer = function(target)
      if target ~= worker and target ~= orchestrator then
        return nil
      end
      return {
        is_responding = function()
          return false
        end,
        get_pending_approval = function()
          return pending
        end,
        get_stop_reason = function()
          return stop_reason
        end,
      }
    end

    -- 本物を通すとCLIターンが走る。何が書かれようとしたかだけ読む
    ProgrammaticSender.validate = function() end
    ProgrammaticSender.send = function(bufnr, message, sender, delivery, opts)
      table.insert(sends, { bufnr = bufnr, message = message, delivery = delivery, opts = opts })
      return { success = true, bufnr = bufnr }
    end
    OrchestrationLink.link_or_warn = function() end
    OrchestrationLink.direction = function()
      return "Request"
    end
    Notifier.on_sent = function() end
  end)

  after_each(function()
    Config.get = originals.config_get
    view.get_chat_buffer = originals.get_chat_buffer
    ProgrammaticSender.send = originals.send
    ProgrammaticSender.validate = originals.validate
    OrchestrationLink.link_or_warn = originals.link_or_warn
    OrchestrationLink.direction = originals.direction
    Notifier.on_sent = originals.on_sent

    for _, buf in ipairs({ worker, orchestrator }) do
      if vim.api.nvim_buf_is_valid(buf) then
        vim.api.nvim_buf_delete(buf, { force = true })
      end
    end
  end)

  ---@param action string
  local function answer(action)
    return ApprovalDelegate.answer({ bufnr = worker, action = action, from_bufnr = orchestrator })
  end

  it("refuses by default, and says what to do instead", function()
    configure(false)

    local ok, err = pcall(answer, "allow_once")

    assert.is_false(ok)
    -- 文面まで見るのは、これを読むのがモデルだから。「無効です」だけだと、次の一手が
    -- 「もう一度呼ぶ」になりうる
    assert.is_truthy(tostring(err):match("Only the user can answer"), tostring(err))
    assert.is_truthy(tostring(err):match("delegated_approval"), tostring(err))
    assert.equals(0, #sends, "nothing may be written into the worker while the gate is closed")
  end)

  it("writes a line the approval parser reads back as the same action", function()
    -- この spec の主眼。書く側（ここ）と読む側（`ChatBuffer:send_message` が使う
    -- `approval_parser`）が食い違うと、代理応答は黙ってただのユーザーメッセージになる
    for _, opt in ipairs(OPTIONS) do
      sends = {}
      answer(opt.value)

      local line = sends[1].message
      assert.is_true(ApprovalParser.is_approval_response(line), line)
      assert.equals(opt.value, ApprovalParser.parse_approval_response(line).action)
    end
  end)

  it("reproduces the numbering the renderer drew, so the transcript reads like a human answer", function()
    answer("allow_for_session")

    assert.equals("3. allow_for_session - Allow for this session", sends[1].message)
  end)

  it("still produces a parseable line when the options are missing", function()
    -- 選択肢を読み取れなかったときの逃げ道も、パターンに合っていなければ意味がない
    local line = ApprovalDelegate.option_line(nil, "deny_once")

    assert.is_true(ApprovalParser.is_approval_response(line), line)
    assert.equals("deny_once", ApprovalParser.parse_approval_response(line).action)
  end)

  it("replaces the prompt section and names the answering chat in the header", function()
    answer("allow_once")

    assert.is_true(sends[1].opts.replace_unsent, "the answered prompt must not stay in the buffer")
    assert.equals("Request", sends[1].delivery.kind)
    assert.is_truthy(sends[1].delivery.from, "the worker's transcript must record who answered")
  end)

  it("refuses an action that is not one of the four", function()
    assert.has_error(function()
      answer("allow")
    end)
    assert.has_error(function()
      ApprovalDelegate.answer({ bufnr = worker, action = nil, from_bufnr = orchestrator })
    end)
    assert.equals(0, #sends)
  end)

  it("refuses a chat that is not waiting on an approval, and names its actual status", function()
    pending = nil
    stop_reason = nil

    local ok, err = pcall(answer, "allow_once")

    assert.is_false(ok)
    assert.is_truthy(tostring(err):match("idle"), tostring(err))
    assert.equals(0, #sends)
  end)

  it("refuses a chat answering its own prompt", function()
    local ok = pcall(function()
      ApprovalDelegate.answer({ bufnr = worker, action = "allow_once", from_bufnr = worker })
    end)

    assert.is_false(ok)
    assert.equals(0, #sends)
  end)

  it("subscribes the answering chat to the turn its answer starts", function()
    local subscribed = {}
    Notifier.on_sent = function(from_bufnr, to_bufnr)
      table.insert(subscribed, { from_bufnr, to_bufnr })
    end

    answer("allow_once")

    assert.same({ { orchestrator, worker } }, subscribed)
  end)

  it("reports which tool it answered, so the caller need not re-read the buffer", function()
    local result = answer("deny_for_session")

    assert.equals("Bash", result.tool)
    assert.equals("deny_for_session", result.action)
    assert.is_true(result.success)
  end)
end)
