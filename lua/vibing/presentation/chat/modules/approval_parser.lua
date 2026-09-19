---@class Vibing.ApprovalParser
---承認プロンプトの1行を**書く**のと**読む**のを、両方ここに置く。
---
---承認ブロックはセクションヘッダではなく、未送信の `## User` セクションの中の素のテキストで、
---`timestamp.lua` の `parse_header` は一度も通らない。つまりこれは独自の形式で、**唯一の読み手が
---このモジュール**というのがその形式の担保になっている。
---
---書く側をここに引き上げたのは #778 で identity が要るようになったから。CLIは1ターンに複数の
---PreToolUse フックを**並列に**起動する（実測: 3本が0.54秒差で重なる）ので、承認プロンプトは
---同時に複数出る。`1. allow_once - Allow this execution only` という行は3つとも同一で、
---どれへの答えかテキストから区別できない。
---
---組み立てが2箇所にあると壊れるものがある: `approval_delegate` は「代理応答の行が、人間が
---選んだ場合に残るはずの行と一字一句同じ」であることを意図して作られていて、transcript を読む
---人間が見出し以外の手がかりを要らないようにしている。だから delegate も `option_line` を通す。
local M = {}

---4つのアクション。語彙の定義は `approval_decision.ACTIONS` ただ1つで、こちらは行の読み書き
---だけを持つ。書き写すと、5つ目を足したときにこのモジュールだけが静かに読めなくなる
---@type string[]
local ACTIONS = require("vibing.application.chat.approval_decision").ACTIONS

---行に載る identity。`## User <!-- unsent -->` と同じ見た目の規約を同じバッファで使っている。
---ユーザーには見えるが、既に毎回見ているものと同じ形なので新しい語彙ではない
local MARKER_FORMAT = " <!-- vibing:req=%s -->"

---identity を読み戻すパターン。**Luaパターンであって正規表現ではない**ので `-` は `%-`
local MARKER_PATTERN = "<!%-%- vibing:req=([^%s]+) %-%->"

---選択肢行そのもののパターン。番号は1行の中の位置ではなく、そのプロンプトの選択肢リスト内の
---連番なので、**複数プロンプトが出ていれば重複する**。帰属は identity だけが決める
---@param action string
---@return string
local function action_pattern(action)
  return "^[>%s]*%d+%.%s*" .. action .. "%s*%-"
end

---承認プロンプトに描く1行を組み立てる（**唯一の組み立て口**）
---
---`index` は行番号ではなく選択肢の連番で、空ラベルを飛ばした結果。レンダラーと delegate が
---同じ採り方をしていないと、ユーザーが残す行と代理応答の行が食い違う
---@param index number 1始まりの選択肢番号
---@param label string `"allow_once - Allow this execution only"` のような表示用ラベル
---@param request_id string? 省略すると identity 無しの行になる（保留が1件のときだけ読める）
---@return string
function M.option_line(index, label, request_id)
  local line = string.format("%d. %s", index, label)
  if request_id and request_id ~= "" then
    line = line .. string.format(MARKER_FORMAT, request_id)
  end
  return line
end

---プロンプトブロックの固定行。**書く側と、剥がす側の両方がここから読む。**
---
---レンダラーが `⚠️` を、`buffer.lua` が `⏱️` と拒否の接頭辞を、それぞれ自分のファイルに literal で
---持っていた。剥がす側（`strip_prompt_lines`）が4つ目の写しを持つと、文面をひとつ直した日に
---「剥がれずに残る行」か「ユーザーの本文を巻き込む条件」のどちらかが黙って生まれる
M.PROMPT_HEADER = "⚠️  Tool approval required"

---ブロックの終端。レンダラーは保留が何件あっても**最後に1回だけ**これを書く
M.INSTRUCTION_LINE = "Delete every option line except the one you want, then press <CR>."

---期限切れの記録行の接頭辞（`ChatBuffer:expire_approval` が書く）
M.EXPIRED_NOTICE_PREFIX = "⏱️  Tool approval expired."

---帰属できなかった答えの説明行の接頭辞（`ChatBuffer:_show_approval_refusal` が書く）
M.REFUSAL_PREFIX = "⚠️  That answer was not applied."

---`Tool:` 以下の詳細行。**ブロックの中でしか参照しない**ので、ユーザーが偶然
---`Command: ...` と書いても巻き込まない
local FIELD_PREFIXES = { "Tool: ", "Command: ", "File: ", "Pattern: ", "URL: " }

---ここから下がプロンプトの一部でありうる、という行
---@param line string
---@return boolean
local function opens_block(line)
  return line == M.PROMPT_HEADER
    or vim.startswith(line, M.EXPIRED_NOTICE_PREFIX)
    or vim.startswith(line, M.REFUSAL_PREFIX)
    or line:match(MARKER_PATTERN) ~= nil
end

---開いているブロックを続ける行。`   ` の字下げは期限切れ注記・一時停止注記・拒否理由の継続行で、
---**開始行を見つけたあとでしか継続と見なさない** — 単独で判定すると、ユーザーが字下げして
---打った本文を消す
---@param line string
---@return boolean
local function continues_block(line)
  if opens_block(line) or line == M.INSTRUCTION_LINE then
    return true
  end
  if vim.startswith(line, "   ") then
    return true
  end
  for _, prefix in ipairs(FIELD_PREFIXES) do
    if vim.startswith(line, prefix) then
      return true
    end
  end
  return false
end

---描かれた承認プロンプトの行だけを落とし、ユーザーが打った本文は残す。
---
---**識別条件はこの関数ひとつ。** 呼び出し側は3つある（ターン途中の描き直し、ターンの終わり、
---そのテストの検証）が、どれも「何がプロンプトの行か」を自分で決めてはいけない。以前はセクション
---ごと捨てていたので判定が要らず、代わりに打ちかけの本文が消えていた。
---
---走査はブロック単位で、開始行（`opens_block`）から継続行が続くあいだ。**案内行に当たったら
---そこで閉じる** — レンダラーがブロックの最後に1回だけ書く行なので、これが一番確かな終端で、
---「その下にユーザーが字下げして書いた本文」を巻き込まずに済む。案内行が消されていれば継続行が
---途切れたところで閉じる。ブロックのあいだの空行は、その先にまだ継続行があるときだけ飲む。
---@param lines string[]
---@return string[] kept プロンプト行を除いた行
---@return number removed 落とした行数
function M.strip_prompt_lines(lines)
  local kept, removed = {}, 0
  local index = 1

  while index <= #lines do
    if not opens_block(lines[index]) then
      table.insert(kept, lines[index])
      index = index + 1
    else
      local last, cursor = index, index
      while cursor <= #lines do
        local line = lines[cursor]
        if line == M.INSTRUCTION_LINE then
          last = cursor
          break
        elseif continues_block(line) then
          last = cursor
          cursor = cursor + 1
        elseif line == "" then
          cursor = cursor + 1
        else
          break
        end
      end
      removed = removed + (last - index + 1)
      index = last + 1
      -- ブロック直後の空行も一緒に。残すと描き直すたびに空行が1行ずつ増える
      while index <= #lines and lines[index] == "" do
        index = index + 1
        removed = removed + 1
      end
    end
  end

  return kept, removed
end

---承認レスポンスかどうかを判定
---@param message string ユーザーメッセージ
---@return boolean
function M.is_approval_response(message)
  if not message or type(message) ~= "string" or message == "" then
    return false
  end

  for line in message:gmatch("[^\r\n]+") do
    for _, action in ipairs(ACTIONS) do
      if line:match(action_pattern(action)) then
        return true
      end
    end
  end

  return false
end

---メッセージに残っている選択肢行を**全部**読む
---
---「最初に一致した行が勝つ」ではない。複数プロンプトが同時に出ている状態でそれをやると、
---消し忘れた行が別の承認への答えとして通る。帰属と曖昧さの判定は `resolve` の仕事で、ここは
---「何が書いてあるか」だけを返す
---@param message string
---@return {action: string, request_id: string?}[]
function M.parse_answers(message)
  local answers = {}
  if not message or type(message) ~= "string" or message == "" then
    return answers
  end

  for line in message:gmatch("[^\r\n]+") do
    for _, action in ipairs(ACTIONS) do
      if line:match(action_pattern(action)) then
        table.insert(answers, { action = action, request_id = line:match(MARKER_PATTERN) })
        break
      end
    end
  end

  return answers
end

---読んだ行を、いま保留中の承認に帰属させる
---
---**曖昧なら拒否する。** 「4行残して `<CR>`」が黙って `allow_once` になる経路は #778 で無くなる:
---不作為から許可が生まれるのは、承認を「意図的な行為」にするというこの変更の趣旨と正面から
---ぶつかる。**待たせる設計だから厳しくできる** — 拒否は何も消費しないので、フックは待ったまま、
---ユーザーは行を直して `<CR>` を押し直すだけで済む。kill する設計なら拒否はターンを1つ捨てる
---高い操作だった。
---
---エラーが1つでもあれば**何も返さない**。部分的に適用してから「残りは曖昧でした」と言うと、
---ユーザーはどこまで通ったのかをバッファから読み取れない
---@param message string
---@param pending_ids string[] いま答えを待っている request_id（順序は表示順）
---@return {request_id: string, action: string}[] answers エラーがあれば空
---@return string[] errors 人間が読んで直せる文面
function M.resolve(message, pending_ids)
  pending_ids = pending_ids or {}
  local is_pending = {}
  for _, id in ipairs(pending_ids) do
    is_pending[id] = true
  end

  local parsed = M.parse_answers(message)
  local errors = {}
  local by_request = {}
  local anonymous = {}

  for _, answer in ipairs(parsed) do
    if answer.request_id then
      by_request[answer.request_id] = by_request[answer.request_id] or {}
      table.insert(by_request[answer.request_id], answer.action)
    else
      table.insert(anonymous, answer.action)
    end
  end

  -- identity 付きの行。同じ request に2行以上なら、どちらを選んだのか本人にしか分からない
  local answers = {}
  for _, id in ipairs(pending_ids) do
    local actions = by_request[id]
    if actions and #actions > 1 then
      table.insert(
        errors,
        string.format(
          "%d option lines are still here for request %s — delete all but the one you mean.",
          #actions,
          id
        )
      )
    elseif actions then
      table.insert(answers, { request_id = id, action = actions[1] })
    end
  end

  -- 保留していない request への答え。期限切れになったものに答えたときがこれで、黙って捨てると
  -- 「選んだのに何も起きない」になる
  for id in pairs(by_request) do
    if not is_pending[id] then
      table.insert(
        errors,
        string.format("Request %s is no longer waiting for an answer — delete its lines.", id)
      )
    end
  end

  -- identity の無い行。保留が1件だけならその1件のものとして読める（従来の形）。複数あるなら
  -- 帰属できないので**推測しない**
  if #anonymous > 0 then
    if #anonymous > 1 or #pending_ids ~= 1 then
      table.insert(
        errors,
        string.format(
          "%d option line(s) here name no request, and %d approval(s) are waiting — keep exactly "
            .. "one line, with its `<!-- vibing:req=... -->` marker intact.",
          #anonymous,
          #pending_ids
        )
      )
    elseif by_request[pending_ids[1]] then
      table.insert(
        errors,
        string.format(
          "Request %s has both a marked and an unmarked option line — delete all but the one you mean.",
          pending_ids[1]
        )
      )
    else
      table.insert(answers, { request_id = pending_ids[1], action = anonymous[1] })
    end
  end

  if #errors > 0 then
    return {}, errors
  end
  return answers, errors
end

-- `generate_response_message` はここにあった。承認から模型に渡す文を組み立てる関数が、実際に
-- 使われている `approval_decision.retry_message` とは別の文面で2つ目として存在していた
-- （本番コードからの参照はゼロで、自分のspecだけが呼んでいた）。まさに
-- `.claude/rules/permissions.md` が禁じている「承認が意味することの2つ目の実装」なので、
-- #778 の抽出と一緒に消した。

return M
