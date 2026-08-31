---@class Vibing.Application.CompletionNotifier
---A が B にリクエストを送ったという事実そのものを購読の登録として扱い、B が応答を終えたら
---A に「B が止まった、読みに行け」とだけ伝える。
---
---エージェント（CLIプロセス）はターンが終われば死ぬので、待ち受けはできない。受け取り方は
---「A に新しいターンを起こす」しかなく、それがこの設計。B から A への質問も、B が A に
---`nvim_chat_send_message` を呼ぶだけで同じ経路に乗る。
---
---購読テーブルもキューも**インメモリのみ**。Neovim が落ちればワーカーチャットも道連れなので、
---`pending-resume.json` のような永続化に意味がない。
local M = {}

local notify = require("vibing.core.utils.notify")

local AUGROUP = "VibingCompletionNotifier"
local DEFAULT_MAX_HOPS = 8

---edges[to_bufnr][from_bufnr] = 購読を張った時点の深さ。
---「to_bufnr が終わったら from_bufnr に知らせる」を表す
---@type table<number, table<number, number>>
local edges = {}

---配達先が応答中だったために積んだ通知。from_bufnr 自身の完了で流す
---@type table<number, {bufnr: number, depth: number}[]>
local pending = {}

---通知チェーンで何回起こされたか。手動送信で 0 に戻る
---@type table<number, number>
local depth = {}

---@return {enabled: boolean, max_hops: number?}
local function settings()
  local config = require("vibing.config").get()
  return (config.agent and config.agent.chat_notifications) or { enabled = false }
end

---@param queue {bufnr: number, depth: number}[]
---@return string
local function build_message(queue)
  local lines = {}
  for _, item in ipairs(queue) do
    local name = vim.api.nvim_buf_is_valid(item.bufnr) and vim.api.nvim_buf_get_name(item.bufnr) or ""
    -- frontmatter の `orchestrated` と同じ表示形式にする。モデルが読みに行く先を、
    -- 記録と別の形で名指ししない
    local display = name ~= "" and require("vibing.core.utils.git").to_display_path(name) or "unnamed"
    table.insert(lines, string.format("- chat buffer %d (%s)", item.bufnr, display))
  end

  return table.concat({
    "The following chat(s) you sent a message to have finished responding:",
    "",
    table.concat(lines, "\n"),
    "",
    "Read each one with nvim_get_buffer({ rpc_port, bufnr }) and decide what to do next.",
    "",
    '"Finished" only means no request is in flight. A chat may have failed, stopped to ask the',
    "user something, or be waiting on a tool approval. Read the tail of the transcript before",
    "treating its task as done.",
    "",
    "If other chats you dispatched are still running, do not start aggregating yet — say what",
    "this one produced and end the turn. You will be woken again when the next one finishes.",
  }, "\n")
end

---積まれた通知のうち done_bufnr についてのものを落とす
---@param queue {bufnr: number, depth: number}[]
---@param done_bufnr number
local function drop_queued(queue, done_bufnr)
  for i = #queue, 1, -1 do
    if queue[i].bufnr == done_bufnr then
      table.remove(queue, i)
    end
  end
end

---@param from_bufnr number
---@param done_bufnr number
---@param edge_depth number
local function enqueue(from_bufnr, done_bufnr, edge_depth)
  local queue = pending[from_bufnr] or {}
  for _, item in ipairs(queue) do
    if item.bufnr == done_bufnr then
      return
    end
  end
  table.insert(queue, { bufnr = done_bufnr, depth = edge_depth })
  pending[from_bufnr] = queue
end

---積まれた通知を1通にまとめて配達する
---
---相手が応答中なら**何もしない**。応答中のバッファに送ると `ChatBuffer:send_message()` が
---進行中のターンを kill する（buffer.lua の「前のリクエストが実行中ならキャンセル」）。
---A が B に投げたあと A 自身のターンが続くのは普通なので、短いタスクほどこの窓に入る。
---積んだままにしておけば、A 自身の VibingResponseDone でここが呼び直される。
---@param from_bufnr number
---@return boolean restarted 配達の結果 from_bufnr が新しいターンを走らせた
local function flush(from_bufnr)
  local queue = pending[from_bufnr]
  if not queue or #queue == 0 then
    return false
  end

  if not vim.api.nvim_buf_is_valid(from_bufnr) then
    pending[from_bufnr] = nil
    return false
  end

  local chat_buf = require("vibing.presentation.chat.view").get_chat_buffer(from_bufnr)
  if not chat_buf then
    pending[from_bufnr] = nil
    return false
  end

  if chat_buf:is_responding() then
    return false
  end

  -- ユーザーが書きかけの `## User` を残しているなら触らない。配達は新しいセクションを足すので、
  -- 下書きは送られないまま宙に浮き、次の<CR>は空のヘッダを読んで「No message to send」になる。
  -- auto_resume が未送信セクションを上書きしないのと同じ扱い。
  -- ユーザーがその下書きを送れば、そのターンの完了でここが呼び直されるので取りこぼさない
  if chat_buf.extract_user_message then
    local draft = chat_buf:extract_user_message()
    if draft and vim.trim(draft) ~= "" then
      return false
    end
  end

  local deepest = 0
  for _, item in ipairs(queue) do
    deepest = math.max(deepest, item.depth)
  end

  local ProgrammaticSender = require("vibing.presentation.chat.modules.programmatic_sender")
  local ok, result = pcall(ProgrammaticSender.send, from_bufnr, build_message(queue))

  -- 配達できて初めてキューを空ける。エッジは既に消費済みなので、先に捨てると失敗した通知は
  -- 二度と再現しない。残しておけば次の完了イベントで作り直しなしに再試行できる
  if ok and result and result.success then
    pending[from_bufnr] = nil
    -- 下げてはいけない。深く連鎖したチャットが、浅い時点で張られたエッジの配達を受けたときに
    -- カウンタが戻ると、max_hops が連鎖を止められなくなる
    depth[from_bufnr] = math.max(depth[from_bufnr] or 0, deepest + 1)

    -- 送信が受理されたことと、ターンが始まったことは別。`ChatBuffer:send_message()` が返すのは
    -- 「リクエストとして扱ったか」で、リミット中の予約（`_try_schedule_instead_of_send`）でも、
    -- `SendMessage.execute` がアダプタ未設定・セッション競合で降りた場合でも true になる。
    -- 後者はストリームを張らないので `VibingResponseDone` が来ず、呼び出し元がこれを再稼働と
    -- 読むとエッジが宙に浮く。始まっていないターンを購読者の待ち先にはできないので、
    -- 送信結果ではなく相手の状態を返す
    return chat_buf:is_responding()
  end

  notify.warn(
    string.format("Could not notify chat %d: %s", from_bufnr, ok and "the chat refused the message" or tostring(result)),
    "Chat Notifications"
  )
  return false
end

---bufnr が誰かの完了を待っているか
---
---`edges[*][bufnr]` は「bufnr が送信した相手が、まだ完了を返していない」を意味する。
---残っているあいだ bufnr は待ち合わせ中で、そのターン終了は完了ではなく中間停止。
---
---逆引きの索引は持たずに走査する。エッジ数はチャット数と同じオーダーで、`forget()` も
---同じ走査をしている。二重管理を増やすほうが、ここでは高くつく
---@param bufnr number
---@return boolean
local function is_waiting_on_others(bufnr)
  for _, subscribers in pairs(edges) do
    if subscribers[bufnr] ~= nil then
      return true
    end
  end
  return false
end

---子待ちを押しのけて親に知らせるべき止まり方か
---
---ワーカーのバッファは誰も見ていないので、質問・承認待ち・エラーで止まったまま保留すると
---誰も対応できない。
---
---読むのは `ChatBuffer:get_stop_reason()` そのもので、`chat_status` の語彙ではない。
---あちらは `responding` / `idle` を混ぜた MCP 向けの合成なので、経由すると「この2つには
---一致してはいけない」という知識をここに持つことになり、停止理由が増えたときに黙って
---「対応不要」に分類する。理由が非nilかどうかだけを見れば、増えた理由は自動的に発火側に入る
---@param bufnr number
---@return boolean
local function stopped_needing_attention(bufnr)
  local chat_buf = require("vibing.presentation.chat.view").get_chat_buffer(bufnr)
  return chat_buf ~= nil and chat_buf:get_stop_reason() ~= nil
end

---A が B に送ったことを購読として記録する
---@param from_bufnr number 送信元（通知を受け取る側）
---@param to_bufnr number 送信先（完了を監視される側）
---@return boolean subscribed 深さ上限などで張らなかった場合 false
function M.subscribe(from_bufnr, to_bufnr)
  local cfg = settings()
  if not cfg.enabled then
    return false
  end

  if type(from_bufnr) ~= "number" or type(to_bufnr) ~= "number" or from_bufnr == to_bufnr then
    return false
  end
  if not (vim.api.nvim_buf_is_valid(from_bufnr) and vim.api.nvim_buf_is_valid(to_bufnr)) then
    return false
  end

  edges[to_bufnr] = edges[to_bufnr] or {}

  -- 同じ (A, B) への複数送信は1本に畳む。A が B に3回送っても通知は1回。
  -- この判定を hop 上限より**前**に置く: 既に張ってあるエッジは生きていて通知も届くのに、
  -- 上限に当たったという理由で「購読しなかった」と警告するのは事実に反する。
  -- 同じワーカーに複数回ブリーフを送るのは `vibing-orchestrate` の通常の手順
  if edges[to_bufnr][from_bufnr] ~= nil then
    return true
  end

  local current = depth[from_bufnr] or 0
  local max_hops = cfg.max_hops or DEFAULT_MAX_HOPS
  if current >= max_hops then
    -- 黙って張らないと、通知が来ない理由がどこにも残らない。A→B→A→B の往復自体は
    -- 正当なユースケース（Bの質問にAが答える）なので、循環検出ではなく深さで止めている
    notify.warn(
      string.format(
        "Chat %d has already been woken %d times without a manual send; not subscribing to chat %d. "
          .. "Send a message in that chat yourself to reset the chain.",
        from_bufnr,
        current,
        to_bufnr
      ),
      "Chat Notifications"
    )
    return false
  end

  edges[to_bufnr][from_bufnr] = current

  return true
end

---A が B にメッセージを送った。購読を張り、逆向きの watchdog エッジを消費する
---
---1つの呼び出しにまとめてあるのは、「送信は購読であると同時に報告でもある」が1つの事実
---だから。2手に分けると呼び出し側が対で呼ぶ規約を負ううえ、引数の意味が2つの呼び出しで
---反転する（`subscribe` の第1引数は通知を受ける側、消費側の第1引数は監視される側）。
---
---消費する理由: B が A に本文そのものを届けたのだから、そのうえ「B が止まった、読みに行け」
---を配ると同じ完了で A を二度起こす。これで watchdog（`on_response_done` の分岐3・例外）が
---届くのは「B が報告せずに止まった」場合だけになる。キューに積まれた未配達の watchdog も
---同じ理由で落とす。
---
---作成時（`nvim_chat_create`）は `subscribe` だけを呼ぶ。まだ何も送っていないので、
---消費すべき報告が無い
---@param from_bufnr number 送信元（通知を受け取る側）
---@param to_bufnr number 送信先（完了を監視される側）
function M.on_message_sent(from_bufnr, to_bufnr)
  M.subscribe(from_bufnr, to_bufnr)

  local subscribers = edges[from_bufnr]
  if subscribers then
    subscribers[to_bufnr] = nil
  end
  if pending[to_bufnr] then
    drop_queued(pending[to_bufnr], from_bufnr)
  end
end

---応答完了。自分宛キューの drain と、購読者への配達を行う
---
---発火判定は3分岐（#639 / #640）:
---  1. 自分宛キューを流せた → この tick で自分が再稼働する → 配達もエッジ消費もしない
---  2. 自分が張った未消費のエッジが残っている → 子待ちでの停止 → 親への配達を保留
---  3. どちらでもない → 本当に止まった → watchdog として購読者へ配達
---2 の例外は `stopped_needing_attention`
---@param bufnr number
function M.on_response_done(bufnr)
  if not settings().enabled then
    return
  end

  -- 自分宛キューの drain が先。配達できた = bufnr はこのターンでは終わっておらず、続きの
  -- ターンが控えている（リミット中なら予約として）ということなので、この完了は購読者に見せない。
  -- 順序を逆にしても防げない理由は architecture.md → Multi-Agent Orchestration（#638）
  if flush(bufnr) then
    -- edges[bufnr] は消費せずに残す。bufnr が本当に止まったときの完了で配達される
    return
  end

  -- 分岐2。エッジテーブルは親子を区別しないので、判定の意味は「誰かの返事を待っている」。
  -- 親へ報告を送った直後もここに入るが、その報告が `on_message_delivered` でエッジを
  -- 消費済みなので、保留するものはもう残っていない
  if is_waiting_on_others(bufnr) and not stopped_needing_attention(bufnr) then
    return
  end

  local subscribers = edges[bufnr]
  if subscribers then
    -- 配達した時点で購読は消える（one-shot）。B が次に完了しても、A が改めて送っていなければ
    -- 通知は飛ばない
    edges[bufnr] = nil
    for from_bufnr, edge_depth in pairs(subscribers) do
      if vim.api.nvim_buf_is_valid(from_bufnr) then
        enqueue(from_bufnr, bufnr, edge_depth)
      end
    end
    for from_bufnr in pairs(subscribers) do
      flush(from_bufnr)
    end
  end
end

---ユーザーが手動送信したので通知チェーンの深さをリセットする
---@param bufnr number
function M.reset_depth(bufnr)
  depth[bufnr] = nil
end

---バッファが消えたので関連する購読・キューを捨てる
---@param bufnr number
function M.forget(bufnr)
  -- autocmdはパターン無しで登録しているので、エディタ内のどのバッファを閉じても走る。
  -- 既定（無効）では状態が空のまま、全テーブルの走査だけが通常の編集操作ごとに起きる
  if not (next(edges) or next(pending) or next(depth)) then
    return
  end

  edges[bufnr] = nil
  pending[bufnr] = nil
  depth[bufnr] = nil

  for _, subscribers in pairs(edges) do
    subscribers[bufnr] = nil
  end
  for _, queue in pairs(pending) do
    drop_queued(queue, bufnr)
  end
end

---autocmdを登録する
---
---`enabled` はここでは見ない。イベント自体は設定に関わらず発火するので、購読側でだけ判定して
---おけば、実行中に設定を変えた場合も追従する。無効時のコストは1ターンにつき空振り1回
function M.setup()
  local group = vim.api.nvim_create_augroup(AUGROUP, { clear = true })

  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "VibingResponseDone",
    callback = function(event)
      local bufnr = event.data and event.data.bufnr
      if type(bufnr) == "number" then
        M.on_response_done(bufnr)
      end
    end,
  })

  vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
    group = group,
    callback = function(event)
      M.forget(event.buf)
    end,
  })
end

return M
