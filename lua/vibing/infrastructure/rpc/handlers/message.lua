---@class Vibing.Infrastructure.RPC.MessageHandler
---RPC handler for programmatic message sending
local M = {}

local ProgrammaticSender = require("vibing.presentation.chat.modules.programmatic_sender")

---宛先が応答中なのでキューに積む（`queue_if_busy`）
---
---リンク（`orchestrated` / `orchestrated_by`）はここでは書かない。積む条件が「宛先が応答中」で、
---`update_frontmatter_list` はその宛先バッファを直接編集するため、いま書くとストリーミングと
---競合する。実際に配達される直前、宛先が idle になった時点で `message_queue` が書く
---@param bufnr number 解決済みの宛先
---@param params {message: string, from_bufnr?: number}
---@param at_capacity boolean 積んだ理由に並列度上限が含まれるか
---@return {success: boolean, queued: boolean, bufnr: number}
local function queue_for_later(bufnr, params, at_capacity)
  -- 自分自身への送信を弾く。`validate` は応答中を理由に断っていたので、この経路が
  -- できるまでは起こりえなかった。積むと自分の配達で自分が再稼働し、しかも相手が自分なので
  -- ペアが作れず `max_round_trips` の抑止も効かない（止められるのは全体予算だけになる）。
  -- `subscribe` と `orchestration_link.link` の同じガードに揃える
  if params.from_bufnr and params.from_bufnr == bufnr then
    error("A chat cannot queue a message to itself")
  end

  local ok, err = require("vibing.application.chat.message_queue").enqueue_message(
    bufnr,
    params.from_bufnr,
    params.message,
    params.task
  )
  if not ok then
    error(err)
  end

  local Notifier = require("vibing.application.chat.completion_notifier")
  if params.from_bufnr then
    Notifier.on_sent(params.from_bufnr, bufnr)
  end

  -- 宛先が応答中で積んだのなら、その宛先自身の完了イベントが配達の合図になる。上限で積んだ
  -- 場合の宛先は idle でありうるので、待っていても自分のイベントは来ない。枠が空いたときに
  -- 配り直してもらう側に登録しておく
  if at_capacity then
    Notifier.hold_for_capacity(bufnr)
  end

  return { success = true, queued = true, bufnr = bufnr }
end

---Send message to chat buffer
---
---宛先は `bufnr` か `file_path` のどちらか一方で指す。パスで指せることが要点で、bufnr は
---Neovim を再起動すれば別のバッファを指すのに対し、frontmatter が記録するパスは残る（#641）。
---閉じているチャットは `chat_locator.open` が背景で開くので、再起動後も frontmatter の
---パスからそのまま繋ぎ直せる
---@param params {bufnr?: number, file_path?: string, message: string, sender?: string, from_bufnr?: number, queue_if_busy?: boolean, task?: string}
---@return {success: boolean, bufnr: number, queued?: boolean}
function M.send_message(params)
  if not params then
    error("Missing parameters")
  end

  -- 宛先の解決は他の副作用より先に済ませる。パスは未オープンのチャットを開く経路を通るので、
  -- ここで失敗するならリンクも購読も張られていない状態で止まってほしい
  local Bufnr = require("vibing.infrastructure.rpc.handlers.bufnr")
  local bufnr = Bufnr.resolve_chat_target(params)
  if not bufnr then
    error("Missing bufnr or file_path parameter")
  end

  -- `from_bufnr` も送信・キュー・リンクのどれより先に検証する。古い番号（典型は Neovim 再起動を
  -- 跨いで使い回された値）を黙って流すと、リンクも購読も無いまま送信だけが成功し、
  -- 訂正できる唯一の相手である呼び出し元に何も伝わらない
  params.from_bufnr = Bufnr.resolve_from_bufnr(params.from_bufnr)

  -- `queue_if_busy` は明示指定したときだけ効く。既定でキューに積むと、弾かれたことを検知して
  -- 待ち直すつもりだった既存の呼び出し元が、成功したものとして先に進む。
  -- 引き受けるのは「待てば解ける」2つだけ: 宛先が応答中と、編集全体が並列度上限に達している。
  -- 無効なバッファや空メッセージは待っても解けないので、これまで通りエラーのまま
  local Concurrency = require("vibing.application.chat.concurrency")
  local at_capacity = Concurrency.at_capacity()

  -- 宛先がいま止めている質問への答えは、待ちにも上限にも当たらない（#788）。答えは**新しいターンを
  -- 始めない** — 開いたままのターンを再開させるだけなので、並列度を1つも増やさない。
  --
  -- ここを通さないと、この経路は2通りに壊れる。`queue_if_busy` なしなら下流の `validate` が
  -- 「応答中」で弾く（大声で失敗するので気づける）。`queue_if_busy` 付きだと呼び出し元に
  -- `queued` が返り、答えは `question_wait_sec`（既定900秒）キューに座ったまま質問が期限切れに
  -- なってから**新しいターン**として配達される。後者は、答えたのに答えにならない
  local answers_question = ProgrammaticSender.has_blocked_question(bufnr)

  if not answers_question then
    if params.queue_if_busy and (ProgrammaticSender.is_responding(bufnr) or at_capacity) then
      return queue_for_later(bufnr, params, at_capacity)
    end

    -- 上限に当たったのに待つ気がない呼び出しは、黙って通さない。人間の<CR>はこの経路を通らない
    -- ので、止まるのは機械が始める送信だけ
    if at_capacity then
      error(Concurrency.at_capacity_message())
    end
  end

  -- レジストリは `validate` でもう一度読まれる。この間に人間が答えてしまえば例外は外れ、
  -- 通常どおり「応答中」で弾かれる — 送れなくなったことが正しい
  local send_opts = answers_question and { answers_blocked_question = true } or nil

  -- `from_bufnr` は任意。必須にすると渡し忘れで送信そのものが失敗し、既存の
  -- オーケストレーション経路が壊れる。渡されなければリンクを張らないだけ（＝従来の動作）
  -- 即配達もキュー配達とまったく同じ組み立てを通す。経路が2本あったころは、相手がたまたま
  -- 応答中だったかどうかで同じ報告の見え方が変わっていた（キュー経由だけが送信元を名乗る）
  local result
  if params.from_bufnr then
    -- リンクは送信より前に書く必要がある（`update_frontmatter_list` はバッファを直接触るので、
    -- 宛先の応答が始まってから書くとストリーミングと競合する）。ただし送信が弾かれると
    -- 行われなかったやり取りの関係だけが永久に残るので、先に送信可能かを確かめる
    ProgrammaticSender.validate(bufnr, params.message, send_opts)
    require("vibing.application.chat.orchestration_link").link_or_warn(params.from_bufnr, bufnr, params.task)

    -- 向きの判定は `link_or_warn` の**後**でよい: 配布ならリンクは今書かれたばかりで
    -- `direction` は Request を返し、報告なら `link` は逆向きガードで何も書かずに戻る
    result = require("vibing.application.chat.delivery_message").deliver(
      { { bufnr = params.from_bufnr, body = params.message } },
      bufnr,
      params.sender,
      send_opts
    )

    -- 宛先が本文より先に `/compact` を走らせた。本文はまだ届いていないので、応答中の宛先に
    -- 積むのと同じ形でキューへ回す — 圧縮ターンの完了で `message_queue.flush` が配達する。
    -- 呼び出し元には `queued` で伝える: 「送った」と読まれると、動いていないトランスクリプトを
    -- ポーリングされる（`queue_if_busy` の返り値と同じ規約）
    if result and result.compacting then
      local ok, err = require("vibing.application.chat.message_queue").enqueue_message(
        bufnr,
        params.from_bufnr,
        params.message,
        params.task
      )
      if not ok then
        error(err)
      end
      result = { success = true, queued = true, compacting = true, bufnr = bufnr }
    end
  else
    -- ProgrammaticSender.send already validates parameters
    result = ProgrammaticSender.send(bufnr, params.message, params.sender, nil, send_opts)
  end

  -- 送ったという事実そのものを購読の登録として扱う。宛先が応答を終えたら送信元に
  -- 「読みに行け」とだけ伝わる（application/chat/completion_notifier.lua）。同時に、逆向きの
  -- watchdog エッジ（宛先が送信元の完了を待っていた分）はこの配達で用済みになるので消える。
  --
  -- 送信の**後**に張るのが要点。上の `validate` は「応答中」を弾くが、その判定とここの間には
  -- リンク書き込み（バッファ編集と2ファイルの保存）が挟まるので状態は変わりうるし、
  -- `send_message()` が false を返す経路もある。先に張ると、送っていないメッセージについて
  -- 「相手が終わった、読みに行け」だけが後から届く。
  --
  -- 遅すぎることはない: CLIの起動は非同期で、宛先の完了は `vim.schedule` 経由なので
  -- この関数が返るより先には走らない
  if params.from_bufnr and result and result.success then
    require("vibing.application.chat.completion_notifier").on_sent(params.from_bufnr, bufnr)
  end

  return result
end

return M
