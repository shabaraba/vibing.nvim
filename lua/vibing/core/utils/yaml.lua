---@class Vibing.Core.Utils.Yaml
---チャットfrontmatterが読み書きするYAMLの部分集合を、1つの実装で往復させる（#717）。
---
---対応するのはこのプラグインが実際に書く形だけ — スカラー、ブロックマップ、ブロック
---シーケンス、そして**シーケンスの要素がマップになる入れ子**。フロー記法(`[a, b]`)、
---アンカー、複数ドキュメント、ブロックスカラー(`|` / `>`)は読まない。YAML仕様への準拠が
---目的ではなく、「同じ入力に対して1つの答えを返す場所が1箇所しかない」ことが目的。
---
---入れ子を扱えることが要件なのは、`orchestrated` のエントリが `path` と `task` を持つため
---（#696のときは行指向パーサーの制約から `<path>|<task>` という独自エンコードで回避していた）。
---@module "vibing.core.utils.yaml"
local M = {}

local INDENT_STEP = 2

---プレーンスカラーとして書けない値。引用符で囲まないと読み戻したときに別物になる
---
---`#` は**前に空白がある場合だけ**コメント開始なので、`PR #688` のような値は途中に
---現れた時点で引用が要る。`true` / 数字は文字列として書いたつもりの値が bool / number に
---化けるため、見た目が同じでも引用する
---@param value string
---@return boolean
local function needs_quote(value)
  if value == "" or value ~= vim.trim(value) then
    return true
  end
  if value:find(": ", 1, true) or value:sub(-1) == ":" then
    return true
  end
  if value:find(" #", 1, true) then
    return true
  end
  if value:find("^[%-%?:,%[%]{}#&%*!|>'\"%%@`]") then
    return true
  end
  -- `~` と `null` は**引用しない**。素のYAMLならどちらもnullだが、このプラグインは
  -- `session_id: ~` を「まだセッションが無い」の目印として文字列で読み書きしてきた。
  -- ここで引用すると `"~"` に変わり、既存のチャットファイルと綴りが食い違う
  if value == "true" or value == "false" then
    return true
  end
  return value:match("^%d+$") ~= nil
end

---@param value any
---@return string
local function encode_scalar(value)
  if type(value) == "boolean" then
    return value and "true" or "false"
  end
  if type(value) == "number" then
    return tostring(value)
  end

  local text = tostring(value)
  if not needs_quote(text) then
    return text
  end
  return '"' .. text:gsub("\\", "\\\\"):gsub('"', '\\"') .. '"'
end

---@param text string 引用符を外した中身
---@return string
local function unescape_double(text)
  return (text:gsub("\\(.)", function(char)
    if char == "n" then
      return "\n"
    elseif char == "t" then
      return "\t"
    end
    return char
  end))
end

---@param text string
---@return string|number|boolean|table|nil
local function decode_scalar(text)
  text = vim.trim(text)
  if text == "" then
    return nil
  end

  local double = text:match('^"(.*)"$')
  if double then
    return unescape_double(double)
  end
  local single = text:match("^'(.*)'$")
  if single then
    return (single:gsub("''", "'"))
  end

  if text == "true" then
    return true
  elseif text == "false" then
    return false
  elseif text == "[]" or text == "{}" then
    return {}
  elseif text:match("^%d+$") then
    return tonumber(text)
  end
  return text
end

---@param line string
---@return integer indent
---@return string content
local function split_indent(line)
  local spaces, rest = line:match("^( *)(.*)$")
  return #spaces, rest
end

---空行とコメント行を飛ばして、次に意味のある行の番号を返す
---@param lines string[]
---@param index integer
---@return integer?
local function significant(lines, index)
  while index <= #lines do
    local line = lines[index]
    if not line:match("^%s*$") and not line:match("^%s*#") then
      return index
    end
    index = index + 1
  end
  return nil
end

---@param content string
---@return boolean
local function is_sequence_line(content)
  return content == "-" or content:match("^%-%s") ~= nil
end

local parse_map, parse_sequence

---値を持たないキーの中身を、次の行のインデントから決める
---@param lines string[]
---@param index integer キー行の番号
---@param indent integer キー行のインデント
---@return table value
---@return integer next_index
local function parse_nested(lines, index, indent)
  local child = significant(lines, index + 1)
  if not child then
    return {}, index + 1
  end

  local child_indent, child_content = split_indent(lines[child])
  if child_indent <= indent then
    -- 値も子も無い `key:` は空リストとして読む（`orchestrated:` の往復がこれ）
    return {}, index + 1
  end

  if is_sequence_line(child_content) then
    return parse_sequence(lines, child, child_indent)
  end
  return parse_map(lines, child, child_indent)
end

---@param lines string[]
---@param index integer
---@param indent integer
---@return table map
---@return integer next_index
function parse_map(lines, index, indent)
  local map = {}

  while true do
    local i = significant(lines, index)
    if not i then
      return map, #lines + 1
    end

    local line_indent, content = split_indent(lines[i])
    if line_indent ~= indent or is_sequence_line(content) then
      return map, i
    end

    local key, inline = content:match("^([%w%.%_%-]+):%s*(.*)$")
    if not key then
      -- 読めない行は落とす。frontmatterは手で書けるので、1行の書き損じで
      -- 残り全部を失うより、その行だけ無かったことにするほうが被害が小さい
      index = i + 1
    elseif inline ~= "" then
      map[key] = decode_scalar(inline)
      index = i + 1
    else
      map[key], index = parse_nested(lines, i, indent)
    end
  end
end

---@param lines string[]
---@param index integer
---@param indent integer
---@return table sequence
---@return integer next_index
function parse_sequence(lines, index, indent)
  local sequence = {}

  while true do
    local i = significant(lines, index)
    if not i then
      return sequence, #lines + 1
    end

    local line_indent, content = split_indent(lines[i])
    if line_indent ~= indent or not is_sequence_line(content) then
      return sequence, i
    end

    local item = content:match("^%-%s*(.*)$")
    -- `- ` の直後がキーなら、この要素はマップ。要素の基準インデントは `-` を空白で
    -- 埋めた位置なので、続きの行（`    task: ...`）がそのまま同じマップに入る
    local item_indent = indent + (#content - #item)

    if item ~= "" and item:match("^[%w%.%_%-]+:") then
      lines[i] = string.rep(" ", item_indent) .. item
      local entry
      entry, index = parse_map(lines, i, item_indent)
      table.insert(sequence, entry)
    elseif item ~= "" then
      table.insert(sequence, decode_scalar(item))
      index = i + 1
    else
      local nested
      nested, index = parse_nested(lines, i, indent)
      table.insert(sequence, nested)
    end
  end
end

---YAMLのブロックを読む
---@param source string|string[] frontmatterの中身（開始/終了の`---`は含めない）
---@return table
function M.decode(source)
  local lines = type(source) == "string" and vim.split(source, "\n", { plain = true }) or vim.list_slice(source)
  if #lines == 0 then
    return {}
  end
  return (parse_map(lines, 1, 0))
end

---@param tbl table
---@param priority table<string, integer>
---@return string[]
local function sorted_keys(tbl, priority)
  local keys = {}
  for key in pairs(tbl) do
    table.insert(keys, key)
  end

  table.sort(keys, function(a, b)
    local pa, pb = priority[a] or math.huge, priority[b] or math.huge
    if pa ~= pb then
      return pa < pb
    end
    return a < b
  end)

  return keys
end

---空テーブルはリストとして書く。マップとリストの区別が付かない唯一の形で、
---このプラグインが空で持つのは常にリスト（`permissions_allow` / `orchestrated`）
---@param value table
---@return boolean
local function is_sequence(value)
  return #value > 0 or next(value) == nil
end

local encode_map, encode_sequence

---@param map table
---@param indent integer
---@param out string[]
---@param priority table<string, integer>
function encode_map(map, indent, out, priority)
  local pad = string.rep(" ", indent)

  for _, key in ipairs(sorted_keys(map, priority)) do
    local value = map[key]
    if type(value) ~= "table" then
      table.insert(out, pad .. key .. ": " .. encode_scalar(value))
    elseif is_sequence(value) then
      table.insert(out, pad .. key .. ":")
      encode_sequence(value, indent + INDENT_STEP, out, priority)
    else
      table.insert(out, pad .. key .. ":")
      encode_map(value, indent + INDENT_STEP, out, priority)
    end
  end
end

---@param sequence table
---@param indent integer
---@param out string[]
---@param priority table<string, integer>
function encode_sequence(sequence, indent, out, priority)
  local pad = string.rep(" ", indent)

  for _, item in ipairs(sequence) do
    if type(item) ~= "table" then
      table.insert(out, pad .. "- " .. encode_scalar(item))
    else
      -- マップ要素は1段深いインデントで書いてから、先頭行の空白2つを `- ` に差し替える。
      -- `- ` が2文字なので桁は動かず、続きの行はそのまま要素の中身として読み戻る
      local nested = {}
      encode_map(item, indent + INDENT_STEP, nested, priority)
      if #nested > 0 then
        nested[1] = pad .. "- " .. nested[1]:sub(indent + INDENT_STEP + 1)
        vim.list_extend(out, nested)
      end
    end
  end
end

---テーブルをYAMLのブロックに書き出す
---@param data table
---@param key_order? string[] この順に前へ出す。載っていないキーは後ろにアルファベット順
---@return string[] lines
function M.encode(data, key_order)
  local priority = {}
  for index, key in ipairs(key_order or {}) do
    priority[key] = index
  end

  local lines = {}
  encode_map(data, 0, lines, priority)
  return lines
end

return M
