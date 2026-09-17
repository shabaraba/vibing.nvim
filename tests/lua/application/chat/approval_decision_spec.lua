--- `approval_decision` は「承認が意味すること」の唯一の実装なので、ここが固定するのは
--- **3つが揃って起きること**であって、それぞれが単独で正しいことではない。
---
--- 承認の消費は (1) セッションリストの更新 (2) プロンプトの破棄 (3) 模型に渡す文の生成 の3つで、
--- どれか1つでも欠けると症状はすべて「ワーカーが同じ壁にまた当たる」に潰れ、エラーはどこにも
--- 出ない。だから consume の戻り値だけでなく、本物の `ChatBuffer` に対する副作用も一緒に見る。
---
--- 本物のバッファを使うのは `approval_delegate_integration_spec.lua` と同じ理由: このモジュールの
--- 契約は `update_session_permissions` / `get_pending_approval` / `clear_pending_approval` との
--- 接続部にあり、スタブに対して緑になっても接続が合っている保証にならない。
local ApprovalDecision = require("vibing.application.chat.approval_decision")
local Config = require("vibing.config")
local CreateChat = require("vibing.application.chat.use_cases.create_chat")
local view = require("vibing.presentation.chat.view")

local OPTIONS = {
  { value = "allow_once", label = "allow_once - Allow this execution only" },
  { value = "deny_once", label = "deny_once - Deny this execution only" },
  { value = "allow_for_session", label = "allow_for_session - Allow for this session" },
  { value = "deny_for_session", label = "deny_for_session - Deny for this session" },
}

describe("approval_decision", function()
  describe("the pure half", function()
    it("names exactly the four answers the rest of the feature speaks", function()
      -- `rpc/handlers/permission.lua` の APPROVAL_OPTIONS と
      -- `approval_parser.APPROVAL_PATTERNS` が同じ4つであることが、UI・パース・代理応答が
      -- 噛み合っている条件
      table.sort(ApprovalDecision.ACTIONS)
      assert.same({ "allow_for_session", "allow_once", "deny_for_session", "deny_once" }, ApprovalDecision.ACTIONS)
    end)

    it("classifies allow and deny answers apart", function()
      assert.is_true(ApprovalDecision.is_allow("allow_once"))
      assert.is_true(ApprovalDecision.is_allow("allow_for_session"))
      assert.is_false(ApprovalDecision.is_allow("deny_once"))
      assert.is_false(ApprovalDecision.is_allow("deny_for_session"))
    end)

    it("rejects anything that is not one of the four", function()
      assert.is_false(ApprovalDecision.is_valid_action("allow"))
      assert.is_false(ApprovalDecision.is_valid_action(nil))
      assert.is_false(ApprovalDecision.is_valid_action(true))
    end)

    it("summarises the one input field that identifies which call was approved", function()
      assert.equals(" (command: npm install)", ApprovalDecision.input_summary("Bash", { command = "npm install" }))
      assert.equals(" (file: /tmp/a.lua)", ApprovalDecision.input_summary("Write", { file_path = "/tmp/a.lua" }))
      assert.equals(" (query: neovim)", ApprovalDecision.input_summary("WebSearch", { query = "neovim" }))
    end)

    it("summarises nothing for a tool it has no identifying field for", function()
      -- 知らないツールの input を丸ごと吐くと、再試行文がツールの中身で膨らむ
      assert.equals("", ApprovalDecision.input_summary("Task", { prompt = "x" }))
      assert.equals("", ApprovalDecision.input_summary("Bash", {}))
      assert.equals("", ApprovalDecision.input_summary("Bash", nil))
    end)

    it("carries the tool and its input into an allow, so the model can repeat the same call", function()
      local message = ApprovalDecision.retry_message("allow_once", "Bash", { command = "npm install" })
      assert.is_truthy(message:match("^I approved the Bash tool"), message)
      assert.is_truthy(message:match("npm install"), message)
    end)

    it("tells the model to take another route on a deny, and does not repeat the input", function()
      local message = ApprovalDecision.retry_message("deny_for_session", "Bash", { command = "npm install" })
      assert.is_truthy(message:match("^I denied the Bash tool"), message)
      -- 拒否された操作の中身を復唱すると、モデルはそれを再試行の指示として読む
      assert.is_nil(message:match("npm install"), message)
    end)

    it("stops instructing once the prompt expired, because the turn went on without it", function()
      -- The two above are written for a turn that stopped *at* the prompt: nothing has happened
      -- since, so an instruction about what to do next is sound. Past the wait limit the call was
      -- refused and the turn carried on — it may have taken another route, or finished. Telling it
      -- to proceed then asks for work that may already be done, and telling it to take another
      -- route describes what it already did. Both assert a state nobody observed.
      local allow = ApprovalDecision.retry_message("allow_once", "Bash", { command = "npm install" }, true)
      local deny = ApprovalDecision.retry_message("deny_for_session", "Bash", { command = "npm install" }, true)

      for _, message in ipairs({ allow, deny }) do
        assert.is_nil(message:find("Please proceed with the same operation", 1, true), message)
        assert.is_nil(message:find("Please use a different approach", 1, true), message)
        -- 我々が知っている事実: 上限で拒否されたこと、そのあともターンが続いたこと
        assert.is_truthy(message:find("unanswered", 1, true), message)
        assert.is_truthy(message:find("carried on", 1, true), message)
      end

      -- The grant still has to be legible as a grant, and a denial as a denial.
      assert.is_truthy(allow:match("^I approved the Bash tool"), allow)
      assert.is_truthy(deny:match("^I denied the Bash tool"), deny)
    end)

    it("does not send the expired wording down the ordinary route", function()
      -- The pairing is the point: collapsing the two back into one is the mutation this exists to
      -- catch, in whichever direction it is done.
      local ordinary = ApprovalDecision.retry_message("allow_once", "Bash", { command = "npm install" })

      assert.is_truthy(ordinary:find("Please proceed with the same operation", 1, true), ordinary)
      assert.is_nil(ordinary:find("carried on", 1, true), ordinary)
    end)
  end)

  describe("consume, against a real ChatBuffer", function()
    local originals = {}
    local save_dir
    local chats

    ---@return Vibing.ChatBuffer
    local function blocked_chat()
      local chat_buf = view.render(CreateChat.execute({}), "back", { background = true })
      table.insert(chats, chat_buf)
      chat_buf:insert_approval_request("Bash", { command = "npm install" }, OPTIONS, "req-1")
      return chat_buf
    end

    before_each(function()
      originals.config_get = Config.get
      save_dir = vim.fn.tempname()
      vim.fn.mkdir(save_dir, "p")
      chats = {}

      local cfg = vim.tbl_deep_extend("force", vim.deepcopy(Config.defaults), {
        chat = { save_location_type = "custom", save_dir = save_dir },
      })
      Config.get = function()
        return cfg
      end
    end)

    after_each(function()
      Config.get = originals.config_get
      for _, chat_buf in ipairs(chats) do
        if vim.api.nvim_buf_is_valid(chat_buf.buf) then
          vim.api.nvim_buf_delete(chat_buf.buf, { force = true })
        end
      end
      vim.fn.delete(save_dir, "rf")
    end)

    it("records the grant, spends the prompt and produces the retry text, all three", function()
      local chat_buf = blocked_chat()

      local consumed, err = ApprovalDecision.consume(chat_buf, { action = "allow_once" })

      assert.is_nil(err)
      -- (1) 許可が記録された
      assert.is_true(vim.tbl_contains(chat_buf:get_session_allow(), "Bash:once"))
      -- (2) プロンプトが消費済みになった
      assert.is_nil(chat_buf:get_pending_approval())
      -- (3) 模型に渡す文ができた
      assert.equals("Bash", consumed.tool)
      assert.equals("allow_once", consumed.action)
      assert.is_true(consumed.is_allow)
      assert.is_truthy(consumed.retry_message:match("^I approved the Bash tool"), consumed.retry_message)
      assert.is_truthy(consumed.retry_message:match("npm install"), consumed.retry_message)
    end)

    it("hands back the input the prompt was raised for, after the prompt is gone", function()
      -- `clear_pending_approval` の後に input を読もうとすると nil になる。呼び出し側が
      -- ツール入力を要るとき（duplex の in-place 応答は `updatedInput` を返す）ここが唯一の出所
      local chat_buf = blocked_chat()

      local consumed = ApprovalDecision.consume(chat_buf, { action = "allow_once" })

      assert.same({ command = "npm install" }, consumed.input)
    end)

    it("records a session denial on the chat's own lists", function()
      local chat_buf = blocked_chat()

      local consumed = ApprovalDecision.consume(chat_buf, { action = "deny_for_session" })

      assert.is_true(vim.tbl_contains(chat_buf:get_session_deny(), "Bash"))
      assert.is_false(consumed.is_allow)
      assert.is_truthy(consumed.retry_message:match("^I denied the Bash tool"))
    end)

    it("refuses to spend a prompt twice", function()
      -- プロンプトは1回しか消費できない。2回目が通ると `:once` の許可がもう1つ積まれ、
      -- 承認1回で2回ツールが通る
      local chat_buf = blocked_chat()
      ApprovalDecision.consume(chat_buf, { action = "allow_once" })

      local consumed, err = ApprovalDecision.consume(chat_buf, { action = "allow_once" })

      assert.is_nil(consumed)
      assert.is_truthy(err)
    end)

    it("refuses an action outside the four, and leaves the prompt answerable", function()
      local chat_buf = blocked_chat()

      local consumed, err = ApprovalDecision.consume(chat_buf, { action = "allow" })

      assert.is_nil(consumed)
      assert.is_truthy(err)
      -- 断った以上、ユーザーが答えられる状態で残っていなければならない
      assert.is_truthy(chat_buf:get_pending_approval())
      assert.equals(0, #chat_buf:get_session_allow())
    end)
  end)
end)
