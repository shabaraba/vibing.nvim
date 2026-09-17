local Timestamp = require("vibing.core.utils.timestamp")

local M = {}

---セクションの内容を会話配列に追加
---@param conversation table 会話配列
---@param role string|nil 現在のロール
---@param content table 内容行の配列
local function save_section(conversation, role, content)
  if role and #content > 0 then
    local content_str = vim.trim(table.concat(content, "\n"))
    if content_str ~= "" then
      table.insert(conversation, {
        role = role,
        content = content_str,
      })
    end
  end
end

---会話履歴全体を抽出
---@param buf number バッファ番号
---@return {role: string, content: string}[]
function M.extract_conversation(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local conversation = {}
  local current_role = nil
  local current_content = {}

  for _, line in ipairs(lines) do
    local role = Timestamp.extract_role(line)

    if role == "user" or role == "assistant" then
      save_section(conversation, current_role, current_content)
      current_role = role
      current_content = {}
    elseif
      current_role
      and not Timestamp.is_header(line)
      and not line:match("^---")
      and not line:match("^Context:")
    then
      table.insert(current_content, line)
    end
  end

  save_section(conversation, current_role, current_content)

  return conversation
end

---ユーザーメッセージを抽出（最後の## Userセクション）
---@param buf number バッファ番号
---@return string?
function M.extract_user_message(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

  local last_user_line = nil
  for i = #lines, 1, -1 do
    local role = Timestamp.extract_role(lines[i])
    if role == "user" then
      last_user_line = i
      break
    end
  end

  if not last_user_line then
    return nil
  end

  local message_lines = {}
  for i = last_user_line + 1, #lines do
    local line = lines[i]
    if Timestamp.is_header(line) then
      break
    end
    table.insert(message_lines, line)
  end

  while #message_lines > 0 and message_lines[1] == "" do
    table.remove(message_lines, 1)
  end
  while #message_lines > 0 and message_lines[#message_lines] == "" do
    table.remove(message_lines)
  end

  if #message_lines == 0 then
    return nil
  end

  return table.concat(message_lines, "\n")
end

---未送信ヘッダーをタイムスタンプ付きヘッダーに置き換える
---
---種別と送信元を保ったまま時刻だけ入れる。`## User` に決め打つと、配達セクション
---（`## Request` / `## Report` / `## Notice`）が送信の瞬間にただの User に化けて、
---誰から届いたものかがバッファから消える
---@param buf number バッファ番号
function M.commit_user_message(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end

  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local last_unsent_line, last_unsent_header = nil, nil

  for i = #lines, 1, -1 do
    local header = Timestamp.parse_header(lines[i])
    if header and header.unsent then
      last_unsent_line, last_unsent_header = i, header
      break
    end
  end

  if not last_unsent_line then
    return
  end

  local committed = Timestamp.create_header(last_unsent_header.kind, Timestamp.now(), last_unsent_header.from)
  vim.api.nvim_buf_set_lines(buf, last_unsent_line - 1, last_unsent_line, false, { committed })
end

---末尾の未送信セクションを落とす（既定では中身が空のときだけ）
---
---ターンが終わるたび `add_user_section()` が空の `## User <!-- unsent -->` を置く。人間はそこに
---打ち込むのでセクションは1つのままだが、配達はその下に**もう1つ**足していたので、配達された
---ターンの上には毎回空の User セクションが取り残されていた（実際のオーケストレーションで
---1ターンにつき1つ増えるのを確認）。
---
---落とすのは中身が空のときだけ。承認プロンプトや質問の選択肢は同じ未送信セクションに描かれる
---ので、それらは「空でない」として残る。`replace_unsent` を渡した呼び出しだけが、その中身ごと
---落とす — 代理承認（答える対象がプロンプトそのもの）と、承認プロンプトを描いたまま終わった
---ターンの締めくくり（同じものを描き直すので、残すと二重になる）の2つ
---@param buf number
---@param replace_unsent boolean?
function M.drop_trailing_unsent_section(buf, replace_unsent)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end

  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

  -- 末尾から空行を飛ばして最初に当たった行がヘッダーなら、それが最後のセクションで、かつ
  -- 中身は空。ヘッダー行が空行であることはないので、この1走査が「最後のヘッダー」と
  -- 「その下は空」の両方を同時に確かめている
  local last = #lines
  while last > 0 and vim.trim(lines[last]) == "" do
    last = last - 1
  end

  if last == 0 then
    return
  end

  if not Timestamp.is_unsent_header(lines[last]) then
    if not replace_unsent then
      return
    end
    -- 中身のある未送信セクションを落とす経路。末尾から**最初に当たったヘッダー**まで戻り、
    -- それが未送信でなければ何もしない。「未送信ヘッダーを見つけるまで遡る」にすると、
    -- 送信済みセクションを飛び越えて上のほうの未送信セクションを消しうる
    repeat
      last = last - 1
    until last == 0 or Timestamp.is_header(lines[last])
    if last == 0 or not Timestamp.is_unsent_header(lines[last]) then
      return
    end
  end

  -- ヘッダーの手前の空行も一緒に落とす。残しても `addUserSection` が末尾の空行を畳むが、
  -- 畳む対象を残したまま返すと「何を消したか」が2箇所に分かれる
  local first = last
  while first > 1 and vim.trim(lines[first - 1]) == "" do
    first = first - 1
  end
  vim.api.nvim_buf_set_lines(buf, first - 1, #lines, false, {})
end

return M
