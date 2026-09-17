---@class Vibing.Application.Chat.ApprovalDelegate
---ワーカーの `waiting_approval` に、別のチャットが代理で答える。
---
---承認プロンプトはターンを殺してから描かれる（`rpc/handlers/permission.lua` の
---`cancel_and_deny`）。止まったチャットは自分では何もできず、報告する手段も残っていないので、
---誰かが外から答えるまで動かない。既定でその「誰か」はユーザーだけで、オーケストレーターは
---「どのチャットが何で止まっているか」を言うところまでしかできない
---（`delivery_message.lua` の `waiting_approval` の説明文）。
---
---`agent.orchestration.delegated_approval` を true にすると、オーケストレーターが4択に無条件で
---代理で答えられるようになる。**opt-in なのは、買っているのが「エージェントが別のエージェントの
---承認ゲートを外せる」状態そのものだから**で、実装上の都合ではない。
---
---`"scoped"` はその中間で、答えるワーカー自身の frontmatter `delegated_scope`
---（`permissions_allow` と同じパターン構文の文字列リスト、`nvim_chat_create` の
---`delegated_scope` 引数で宣言する）に一致する allow 系の答えだけを通す。deny 系の答えは
---範囲を問わず常に通す — 拒否は権限を広げないので、機械的に判断してよい。判断は
---`matchers.matches_permission` に委ねる。承認ルールの構文を2つ持たないための形。
---
---答えは人間の `<CR>` とまったく同じ経路を通る。選んだ選択肢の行をワーカーのバッファに
---書いてから `ChatBuffer:send_message()` を呼ぶだけで、承認の消費
---（`update_session_permissions` → プロンプトの破棄 → フックへの判定 or 再試行文への差し替え）は
---`ChatBuffer:_answer_pending_approval` が行う。判断ロジックを2本持たないための形で、代理応答
---だけが `:once` の扱いやセッションリストの更新で人間の経路と食い違う、という壊れ方をしない。
---
---合流点が `send_message` の**冒頭**（`cancel_request()` より前）なのはそのため。承認を kill
---せずに答えられるようになった以上、答えは新しいターンではなく走っているターンの続きで、
---人間側だけを直すと代理承認だけが「答えた瞬間にターンが死ぬ」形で壊れる
---
---人間の経路と違うのは書かれるセクション見出しだけ: 代理応答は
---`## Request <!-- <時刻> from .vibing/chat/orchestrator.md -->` として残るので、
---「誰が許可したのか」がワーカーの transcript から読める。差し替え後の本文が
---「I approved the Bash tool ...」と一人称なのはそのままでよく、その "I" は見出しが
---名指ししているチャットを指す。
local M = {}

---代理で答えられる4択。語彙は `approval_decision` が持つ — ここに写しを置くと、選択肢が増えた
---ときに代理応答だけが古い4択で検証し続ける
---@type string[]
M.ACTIONS = require("vibing.application.chat.approval_decision").ACTIONS

---@param action any
---@return boolean
local function is_valid_action(action)
  return require("vibing.application.chat.approval_decision").is_valid_action(action)
end

---`agent.orchestration.delegated_approval` の実効値
---
---`concurrency.limit()` と同じ理由で型を見る: `orchestration = true` のような壊れた設定で、
---`setup()` 後のあらゆる代理応答が落ちるのではなく「無効」に倒れてほしい
---@return boolean|"scoped"
function M.mode()
  local config = require("vibing.config").get()
  local orchestration = config.agent and config.agent.orchestration
  if type(orchestration) ~= "table" then
    return false
  end
  local value = orchestration.delegated_approval
  if value == true or value == "scoped" then
    return value
  end
  return false
end

---この機能が(全面的にでも、範囲付きでも)有効か
---@return boolean
function M.enabled()
  return M.mode() ~= false
end

---deny系の答えか（deny系は範囲を問わず常に委任できる — 拒否は権限を広げないため）
---@param action string
---@return boolean
local function is_deny_action(action)
  return action == "deny_once" or action == "deny_for_session"
end

---`"scoped"` モードで、この答えを代理で送ってよいか。deny系は範囲を問わず常に通す
---（拒否は権限を広げないため）— この判断を呼び出し側と分けないのは、範囲チェックを
---要る場所すべてがdeny系の特別扱いを自分で足し忘れない・落とし忘れないための一箇所
---@param chat_buf table ワーカーの ChatBuffer
---@param pending {tool: string, input: table}
---@param action string
---@return boolean
local function is_allowed_by_scope(chat_buf, pending, action)
  if is_deny_action(action) then
    return true
  end
  local scope = chat_buf:get_frontmatter_list("delegated_scope")
  local matchers = require("vibing.infrastructure.permissions.matchers")
  for _, pattern in ipairs(scope) do
    if matchers.matches_permission(pending.tool, pending.input or {}, pattern) then
      return true
    end
  end
  return false
end

---承認プロンプトに描かれたのと同じ行を組み立てる
---
---`approval_parser` が読むのは番号付きリストの行（`1. allow_once - ...`）なので、番号もラベルも
---レンダラーが描いたものに合わせる。番号の採り方（空ラベルを飛ばす）を
---`renderer.lua` と揃えてあるのは、バッファに残る行が「ユーザーが選んだ場合に残るはずの行」と
---一字一句同じであってほしいため — transcript を読む人間が、代理応答かどうかを見分けるのに
---見出し以外の手がかりを要らなくする
---@param options table? 承認プロンプトの `options`
---@param action string
---@param request_id string? 行に載せる identity。複数の承認が同時に出ているとき、番号だけでは
---  どれへの答えか決まらない
---@return string
function M.option_line(options, action, request_id)
  -- 行を組み立てるのは `approval_parser.option_line` **だけ**。ここで自分で `string.format`
  -- すると、人間が残す行と代理応答の行が別々に進化して、この関数の意図（一字一句同じ）が
  -- 黙って壊れる
  local ApprovalParser = require("vibing.presentation.chat.modules.approval_parser")

  local index = 1
  for _, opt in ipairs(options or {}) do
    local label = (opt.label and opt.label ~= "") and opt.label or ""
    if label ~= "" then
      if opt.value == action then
        return ApprovalParser.option_line(index, label, request_id)
      end
      index = index + 1
    end
  end

  -- 選択肢を読み取れなかったときの逃げ道。`- ` の後ろまで含めて書くのは、パターンが
  -- ハイフンまでを要求するため
  return ApprovalParser.option_line(1, action .. " - answered by another chat", request_id)
end

---ワーカーの承認プロンプトに代理で答える
---@param params {bufnr: number, action: string, from_bufnr: number, request_id: string?}
---  `request_id` は保留が2件以上あるとき必須。CLIは1ターンに複数のフックを並列に起動するので
---  「そのチャットの承認」は1つに決まらず、省略されたら**どれに答えたつもりか分からない**
---@return {success: boolean, bufnr: number, tool: string, action: string}
function M.answer(params)
  local mode = M.mode()
  if mode == false then
    error(
      "Delegated tool approval is disabled. Only the user can answer this chat's tool-approval "
        .. "prompt: say which chat is blocked and on which tool, and let the user answer it in "
        .. "that chat. (The user can enable it with "
        .. "agent.orchestration.delegated_approval = true (or \"scoped\") in their vibing.nvim "
        .. "setup.)"
    )
  end

  if not is_valid_action(params.action) then
    error(
      string.format(
        "Invalid action: %s (expected one of: %s)",
        tostring(params.action),
        table.concat(M.ACTIONS, ", ")
      )
    )
  end

  local bufnr, from_bufnr = params.bufnr, params.from_bufnr

  -- 自分自身の承認に答えるのは通せない。答えるチャットは止まっていなければならないが、
  -- この呼び出しをしているチャットは走っている。`send_message` の同じガードに揃える
  if from_bufnr == bufnr then
    error("A chat cannot answer its own tool-approval prompt")
  end

  local ProgrammaticSender = require("vibing.presentation.chat.modules.programmatic_sender")
  local chat_buf = require("vibing.presentation.chat.view").get_chat_buffer(bufnr)
  if not chat_buf then
    error("Buffer is not a vibing chat buffer")
  end

  -- 2件以上あるのに名指しが無ければ、どれに答えたのか誰にも分からない。推測して1つ選ぶと、
  -- オーケストレータが意図していない承認が通る
  local waiting = chat_buf:get_pending_approvals()
  if #waiting > 1 and not params.request_id then
    local ids = {}
    for _, entry in ipairs(waiting) do
      table.insert(ids, string.format("%s (%s)", tostring(entry.request_id), tostring(entry.tool)))
    end
    error(
      string.format(
        "That chat has %d tool-approval prompts waiting at once, so `request_id` is required: %s. "
          .. "Read the chat with nvim_get_buffer — each option line carries its own "
          .. "`<!-- vibing:req=... -->` marker.",
        #waiting,
        table.concat(ids, ", ")
      )
    )
  end

  local pending = chat_buf:get_pending_approval(params.request_id)
  if not pending then
    -- 状態を名乗る。「承認待ちではない」だけだと、呼び出し元は `nvim_get_buffer` を1往復して
    -- 同じことを知りに行くしかない。語彙は watchdog の通知や `nvim_get_buffer` と同じ
    local status = require("vibing.presentation.chat.modules.chat_status").get(bufnr) or "unknown"
    error(
      string.format(
        "That chat is not waiting on a tool approval (status: %s). "
          .. "A tool-approval prompt can only be answered once, and only while it is pending.",
        status
      )
    )
  end

  -- 期限切れは**ここで名指しで断る**。プロンプトは消さずに印を付けて残す方針で、
  -- `waiting_approvals` も `expired = true` を付けて返すので、オーケストレーターはこれを見て
  -- 答えに来る。待たせる設計ではそのときターンはまだ走っているので、黙って下流に流すと
  -- `ProgrammaticSender.validate` の「応答中なので送れない」が先に答えてしまう — 事実だが、
  -- 読み手（モデル）を「空くのを待つ」に誘導する。実際に起きたのは「この承認はもう終わった」で、
  -- 待っても変わらない
  if pending.expired then
    error(
      string.format(
        "That tool-approval prompt (%s) expired before it was answered, so vibing.nvim already "
          .. "denied that one call. Waiting will not change it. The chat's turn may still be "
          .. "running; check `waiting_approvals` again for one that is not expired.",
        tostring(pending.request_id)
      )
    )
  end

  -- "scoped" では allow 系の答えだけを `delegated_scope` に照らす（deny系の特別扱いは
  -- `is_allowed_by_scope` の中）。これが無いと、範囲外のツールを止める（＝安全側に倒す）
  -- ことすらユーザー待ちになり、この機能が解決したい待ち時間をかえって増やす
  if mode == "scoped" and not is_allowed_by_scope(chat_buf, pending, params.action) then
    error(
      string.format(
        "This chat's declared delegated_scope does not cover the %s tool with this input, so "
          .. "only the user can allow it. Say which chat is blocked and on what, and let the "
          .. "user answer it (or widen delegated_scope in that chat's frontmatter). "
          .. "A deny_once/deny_for_session answer is always allowed regardless of scope.",
        tostring(pending.tool)
      )
    )
  end

  local line = M.option_line(pending.options, params.action, pending.request_id)

  -- 送れる状態かを先に確かめる。この後の `link_or_warn` は宛先のバッファを直接編集し、
  -- `replace_unsent` は承認プロンプトそのものを消すので、送信が弾かれるならその前に止まって
  -- ほしい（`rpc/handlers/message.lua` が同じ順序を取っている理由と同じ）
  -- `answers_blocked_approval` を渡すのは、フックがブロックしているワーカーが
  -- `is_responding()` のままだから（#778）。渡さないと「応答中なので送れない」で弾かれ、
  -- 代理承認はその場で答えられる経路でだけ必ず失敗する。例外が効くのは実際に止まっている
  -- フックへの答えだけで、判定は `programmatic_sender` 側がレジストリに訊く
  ProgrammaticSender.validate(bufnr, line, { answers_blocked_approval = pending.request_id })

  -- 承認に答えると、そのワーカーは新しいターンを始める**ことがある**。並列度の上限は「機械が
  -- 始める送信」にかかるものなので、そのときだけ見る。
  --
  -- **その場で答えられる承認では見てはいけない。** フックがブロックしているということは、
  -- そのワーカーは既に走っていて枠を1つ占有している。ここで断ると、既に数えられている枠を
  -- 理由に承認を拒否することになり、しかも断られたワーカーは承認待ちのまま — 枠が上限なら、
  -- 答えることで枠を空けることもできない。ほぼデッドロックになる
  local starts_new_turn = not require("vibing.infrastructure.rpc.pending_approvals").get(pending.request_id)
  local Concurrency = require("vibing.application.chat.concurrency")
  if starts_new_turn and Concurrency.at_capacity() then
    error(
      string.format(
        "%d chats and %d of their subagents are already in flight, at or above the configured "
          .. "limit (agent.orchestration.max_concurrent = %d, max_concurrent_subagents = %d). "
          .. "The approval prompt is still pending — answer it again once one of them finishes.",
        Concurrency.responding_count(),
        Concurrency.subagent_count(),
        Concurrency.limit(),
        Concurrency.subagent_limit()
      )
    )
  end

  local OrchestrationLink = require("vibing.application.chat.orchestration_link")
  OrchestrationLink.link_or_warn(from_bufnr, bufnr)

  -- 向きは `link_or_warn` の後で聞く。配布側からの応答ならリンクは今書かれたばかりで
  -- `Request` を返し、逆向き（ワーカーが親の承認に答える）なら `Report` になる
  local from_name = vim.api.nvim_buf_is_valid(from_bufnr) and vim.api.nvim_buf_get_name(from_bufnr) or ""
  local section = {
    kind = OrchestrationLink.direction(from_bufnr, bufnr),
    from = from_name ~= "" and require("vibing.core.utils.git").to_display_path(from_name) or nil,
  }

  local result = ProgrammaticSender.send(bufnr, line, nil, section, {
    replace_unsent = true,
    answers_blocked_approval = pending.request_id,
  })

  -- 送信と同じく、答えたという事実を購読の登録として扱う。代理で答えたなら、その結果として
  -- ワーカーが動き出し、また止まる。止まったことを知りたいのは答えた側
  if result and result.success then
    require("vibing.application.chat.completion_notifier").on_sent(from_bufnr, bufnr)
  end

  return {
    success = result and result.success or false,
    bufnr = bufnr,
    tool = pending.tool,
    action = params.action,
  }
end

return M
