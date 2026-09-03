---@class Vibing.Application.Chat.ApprovalDelegate
---ワーカーの `waiting_approval` に、別のチャットが代理で答える。
---
---承認プロンプトはターンを殺してから描かれる（`rpc/handlers/permission.lua` の
---`cancel_and_deny`）。止まったチャットは自分では何もできず、報告する手段も残っていないので、
---誰かが外から答えるまで動かない。既定でその「誰か」はユーザーだけで、オーケストレーターは
---「どのチャットが何で止まっているか」を言うところまでしかできない
---（`delivery_message.lua` の `waiting_approval` の説明文）。
---
---`agent.orchestration.delegated_approval` を true にすると、オーケストレーターが4択に代理で
---答えられるようになる。**opt-in なのは、買っているのが「エージェントが別のエージェントの
---承認ゲートを外せる」状態そのものだから**で、実装上の都合ではない。
---
---答えは人間の `<CR>` とまったく同じ経路を通る。選んだ選択肢の行をワーカーのバッファに
---書いてから `ChatBuffer:send_message()` を呼ぶだけで、承認の消費
---（`update_session_permissions` → `_pending_approval` の破棄 → 再試行文への差し替え）は
---既存の承認ブロックが行う。判断ロジックを2本持たないための形で、代理応答だけが
---`:once` の扱いやセッションリストの更新で人間の経路と食い違う、という壊れ方をしない。
---
---人間の経路と違うのは書かれるセクション見出しだけ: 代理応答は
---`## Request <!-- <時刻> from .vibing/chat/orchestrator.md -->` として残るので、
---「誰が許可したのか」がワーカーの transcript から読める。差し替え後の本文が
---「I approved the Bash tool ...」と一人称なのはそのままでよく、その "I" は見出しが
---名指ししているチャットを指す。
local M = {}

---代理で答えられる4択。`rpc/handlers/permission.lua` の `APPROVAL_OPTIONS` と同じ語彙で、
---`presentation/chat/modules/approval_parser.lua` がバッファから読み戻す側
---@type string[]
M.ACTIONS = { "allow_once", "deny_once", "allow_for_session", "deny_for_session" }

---@param action any
---@return boolean
local function is_valid_action(action)
  return type(action) == "string" and vim.tbl_contains(M.ACTIONS, action)
end

---この機能が有効か
---
---`concurrency.limit()` と同じ理由で型を見る: `orchestration = true` のような壊れた設定で、
---`setup()` 後のあらゆる代理応答が落ちるのではなく「無効」に倒れてほしい
---@return boolean
function M.enabled()
  local config = require("vibing.config").get()
  local orchestration = config.agent and config.agent.orchestration
  if type(orchestration) ~= "table" then
    return false
  end
  return orchestration.delegated_approval == true
end

---承認プロンプトに描かれたのと同じ行を組み立てる
---
---`approval_parser` が読むのは番号付きリストの行（`1. allow_once - ...`）なので、番号もラベルも
---レンダラーが描いたものに合わせる。番号の採り方（空ラベルを飛ばす）を
---`renderer.lua` と揃えてあるのは、バッファに残る行が「ユーザーが選んだ場合に残るはずの行」と
---一字一句同じであってほしいため — transcript を読む人間が、代理応答かどうかを見分けるのに
---見出し以外の手がかりを要らなくする
---@param options table? `_pending_approval.options`
---@param action string
---@return string
function M.option_line(options, action)
  local index = 1
  for _, opt in ipairs(options or {}) do
    local label = (opt.label and opt.label ~= "") and opt.label or ""
    if label ~= "" then
      if opt.value == action then
        return string.format("%d. %s", index, label)
      end
      index = index + 1
    end
  end

  -- 選択肢を読み取れなかったときの逃げ道。`- ` の後ろまで含めて書くのは、パターンが
  -- ハイフンまでを要求するため（`approval_parser.APPROVAL_PATTERNS`）
  return string.format("1. %s - answered by another chat", action)
end

---ワーカーの承認プロンプトに代理で答える
---@param params {bufnr: number, action: string, from_bufnr: number}
---@return {success: boolean, bufnr: number, tool: string, action: string}
function M.answer(params)
  if not M.enabled() then
    error(
      "Delegated tool approval is disabled. Only the user can answer this chat's tool-approval "
        .. "prompt: say which chat is blocked and on which tool, and let the user answer it in "
        .. "that chat. (The user can enable it with "
        .. "agent.orchestration.delegated_approval = true in their vibing.nvim setup.)"
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

  local pending = chat_buf:get_pending_approval()
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

  local line = M.option_line(pending.options, params.action)

  -- 送れる状態かを先に確かめる。この後の `link_or_warn` は宛先のバッファを直接編集し、
  -- `replace_unsent` は承認プロンプトそのものを消すので、送信が弾かれるならその前に止まって
  -- ほしい（`rpc/handlers/message.lua` が同じ順序を取っている理由と同じ）
  ProgrammaticSender.validate(bufnr, line)

  -- 承認に答えると、そのワーカーは新しいターンを始める。並列度の上限は「機械が始める送信」に
  -- かかるものなので、ここも見る。ただし `at_capacity_message` は使わない — あれは
  -- `queue_if_busy` を勧める文面で、このツールにその引数は無い。承認は溜めて後で配るような
  -- ものでもない（プロンプトは1回しか消費できず、待つ側は止まったままでいる）ので、
  -- 断って呼び直させる
  local Concurrency = require("vibing.application.chat.concurrency")
  if Concurrency.at_capacity() then
    error(
      string.format(
        "%d chats are already responding, which is the configured limit "
          .. "(agent.orchestration.max_concurrent = %d). The approval prompt is still pending — "
          .. "answer it again once one of them finishes.",
        Concurrency.responding_count(),
        Concurrency.limit()
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

  local result = ProgrammaticSender.send(bufnr, line, nil, section, { replace_unsent = true })

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
