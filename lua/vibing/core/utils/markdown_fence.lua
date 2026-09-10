---コードフェンスを行単位で正規化する
---
---閉じフェンスの直後に文章が続く行（`` ```続きの文章 ``）は CommonMark では閉じフェンスでは
---なく本文で、`tree-sitter-vibing` のスキャナ（`tree-sitter-vibing/src/scanner.c`）も同じ規則を
---採っている。つまりブロックは閉じないまま次のメッセージヘッダーまで伸び、そこまでの
---チャット全体がコードとしてハイライトされる。書き込む側でフェンスと後続テキストを別々の行に
---割って、そもそもその行を作らせない。
---
---**言語名に見える1語（`` ```json ``）は割らない。** ブロック内のそれは CommonMark でも本文
---なので、markdown を markdown で説明する入れ子の例をこちらが書き換えてしまう。割るのは
---空白や非 ASCII を含む「情報文字列には見えない」残りだけ。

local Timestamp = require("vibing.core.utils.timestamp")

---@class Vibing.Utils.MarkdownFence.State
---@field marker string "`" | "~"
---@field length number 開きフェンスのマーカー数

---@class Vibing.Utils.MarkdownFence
local M = {}

-- CommonMark がフェンスとして認めるインデントの上限
local MAX_INDENT = 3

---フェンスに見える行を分解する
---@param line string
---@return string? marker
---@return number? length
---@return string? rest マーカーの後ろに残った文字列
local function fence_parts(line)
  local indent = line:match("^ *")
  if #indent > MAX_INDENT then
    return nil
  end

  local body = line:sub(#indent + 1)
  local marker = body:sub(1, 1)
  if marker ~= "`" and marker ~= "~" then
    return nil
  end

  local run = body:match("^" .. marker .. "+")
  if #run < 3 then
    return nil
  end

  return marker, #run, body:sub(#run + 1)
end

---情報文字列（言語名）に見えるか
---@param rest string
---@return boolean
local function looks_like_info_string(rest)
  return rest:match("^[%w_%.%+#-]+$") ~= nil
end

---`## summary` 境界か（大文字小文字を区別しない）
---
---`Timestamp.is_header` は User / Assistant / Request / Report / Notice しか認めないが、
---`tree-sitter-vibing/grammar.js` の `message_header` と `scanner.c` の `consume_message_header`
---は `summary` も同じ境界として扱う（`summary_inserter.lua` が書く `## summary` ブロックが
---フェンスの中身に引きずられて壊れないように）。ここで別チェックにしているのは、
---`Timestamp.is_header` 自体を緩めると `parse_header` を読む他の全呼び出し側
---（`extract_role` など）に未知の kind が流れ込むため
---@param line string
---@return boolean
local function is_summary_header(line)
  return line:match("^## [Ss][Uu][Mm][Mm][Aa][Rr][Yy]$") ~= nil
    or line:match("^## [Ss][Uu][Mm][Mm][Aa][Rr][Yy] ") ~= nil
end

---1行分だけ状態を進める
---@param state Vibing.Utils.MarkdownFence.State?
---@param line string
---@return Vibing.Utils.MarkdownFence.State? state
---@return string? head 分割するときのフェンス側の行
---@return string? tail 分割するときの後続テキスト
local function step(state, line)
  local marker, length, rest = fence_parts(line)

  if not state then
    -- バッククォートのフェンスは情報文字列にバッククォートを持てない（CommonMark）
    if marker and not (marker == "`" and rest:find("`", 1, true)) then
      return { marker = marker, length = length }
    end
    return nil
  end

  -- チャット境界は未閉のフェンスを打ち切る（スキャナ側の `consume_message_header` と同じ扱い）
  if Timestamp.is_header(line) or is_summary_header(line) then
    return nil
  end

  if marker ~= state.marker or length < state.length then
    return state
  end

  local tail = vim.trim(rest)
  if tail == "" then
    return nil
  end
  if looks_like_info_string(tail) then
    return state
  end

  -- 後続テキストの先頭空白は落とす。残したまま次の行にすると、4個以上でインデント
  -- コードブロックになり、フェンスを割った意味がなくなる
  return nil, line:sub(1, #line - #rest), tail
end

---閉じフェンスに続く文章を次の行へ送り出す
---@param lines string[]
---@param state Vibing.Utils.MarkdownFence.State? 先頭行の時点で開いているフェンス
---@return string[] normalized
---@return Vibing.Utils.MarkdownFence.State? state 末尾行まで進めた状態
function M.normalize(lines, state)
  local result = {}

  for _, line in ipairs(lines) do
    local next_state, head, tail = step(state, line)
    if head then
      table.insert(result, head)
      table.insert(result, tail)
    else
      table.insert(result, line)
    end
    state = next_state
  end

  return result, state
end

---書き換えずに状態だけ求める（既にバッファへ書かれた行の続きを正規化するために使う）
---@param lines string[]
---@param state Vibing.Utils.MarkdownFence.State?
---@param first number? 走査開始インデックス（既定 1）
---@param last number? 走査終了インデックス（既定 #lines）
---@return Vibing.Utils.MarkdownFence.State? state
function M.scan(lines, state, first, last)
  for index = first or 1, last or #lines do
    state = (step(state, lines[index]))
  end
  return state
end

return M
