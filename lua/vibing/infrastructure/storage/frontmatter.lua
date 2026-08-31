local M = {}

local FRONTMATTER_START = "---"
local FRONTMATTER_END = "---"

local function trim(s)
  return s:match("^%s*(.-)%s*$")
end

local function parse_yaml_value(value)
  if value == nil or value == "" then
    return nil
  end

  value = trim(value)

  if value == "true" then
    return true
  elseif value == "false" then
    return false
  elseif value:match("^%d+$") then
    return tonumber(value)
  else
    return value
  end
end

local function parse_yaml_simple(yaml_str)
  local result = {}
  local lines = vim.split(yaml_str, "\n", { plain = true })
  local current_array_key = nil
  local current_array = nil

  for _, line in ipairs(lines) do
    if line:match("^%s*$") then
      goto continue
    end

    local array_item = line:match("^%s+%-%s*(.*)$")
    if array_item and current_array_key then
      table.insert(current_array, trim(array_item))
      goto continue
    end

    local key, value = line:match("^([%w%.%_%-]+):%s*(.*)$")
    if key then
      if current_array_key then
        result[current_array_key] = current_array
        current_array_key = nil
        current_array = nil
      end

      -- Handle empty array notation: []
      if value == "[]" then
        result[key] = {}
      elseif value == "" or value == nil then
        current_array_key = key
        current_array = {}
      else
        result[key] = parse_yaml_value(value)
      end
    end

    ::continue::
  end

  if current_array_key then
    result[current_array_key] = current_array
  end

  return result
end

---旧frontmatterキー名 → 実行時キー名。`permissions_mode`(複数形)は過去のREADMEが案内していた
---綴りで、実行時に読まれるのは`permission_mode`(単数形)だった。
---@type table<string, string>
M.LEGACY_KEY_ALIASES = {
  permissions_mode = "permission_mode",
}

---旧キー名を実行時キー名へ寄せる(正式なキーが既にあればそちらを優先)
---@param parsed table
local function normalize_legacy_keys(parsed)
  for legacy, canonical in pairs(M.LEGACY_KEY_ALIASES) do
    if parsed[legacy] ~= nil then
      if parsed[canonical] == nil then
        parsed[canonical] = parsed[legacy]
      end
      parsed[legacy] = nil
    end
  end
end

function M.parse(content)
  if not content or content == "" then
    return nil, content
  end

  local lines = vim.split(content, "\n", { plain = true })

  if #lines < 1 or trim(lines[1]) ~= FRONTMATTER_START then
    return nil, content
  end

  local end_index = nil
  for i = 2, #lines do
    if trim(lines[i]) == FRONTMATTER_END then
      end_index = i
      break
    end
  end

  if not end_index then
    return nil, content
  end

  local yaml_lines = {}
  for i = 2, end_index - 1 do
    table.insert(yaml_lines, lines[i])
  end
  local yaml_str = table.concat(yaml_lines, "\n")

  local body_lines = {}
  for i = end_index + 1, #lines do
    table.insert(body_lines, lines[i])
  end
  local body = table.concat(body_lines, "\n")

  local parsed = parse_yaml_simple(yaml_str)
  normalize_legacy_keys(parsed)

  return parsed, body
end

---リストフィールドの値を配列として読む
---
---パーサが同じフィールドに対して3つの形を返しうるので、その規則はパーサの隣に置く。
---値なしの `key:` は**真値の空table**（`if not value` では弾けない）、手書きの
---`key: path.md` は**文字列**、通常のブロックリストだけが配列になる
---@param value any
---@return string[]
function M.as_list(value)
  if type(value) == "string" and value ~= "" then
    return { value }
  end
  if type(value) ~= "table" then
    return {}
  end
  return value
end

local function serialize_value(value)
  if type(value) == "boolean" then
    return value and "true" or "false"
  elseif type(value) == "number" then
    return tostring(value)
  else
    return tostring(value)
  end
end

---frontmatterに書き出すキーの順序。**並びそのもの**が定義なので、キーを挿入するときは
---この配列の狙った位置に足すだけでよい（連番を振り直す必要がなく、番号の重複も表現できない）。
---ここに無いキーは後ろにまとめてアルファベット順で並ぶ。
---
---`forked_from` / `subagent_id` / `orchestrated*` が設定値より前にあるのは、どれも
---「このチャットが他のどのチャットと繋がっているか」を答えるフィールドだから。
local KEY_ORDER = {
  "vibing.nvim",
  "session_id",
  "created_at",
  "forked_from",
  "subagent_id",
  "orchestrated",
  "orchestrated_by",
  "working_dir",
  "agent",
  "model",
  "effort",
  "permission_mode",
  "permissions_allow",
  "permissions_deny",
  "permissions_ask",
  "language",
}

local priority = {}
for index, key in ipairs(KEY_ORDER) do
  priority[key] = index
end

local function get_sorted_keys(tbl)
  local keys = {}
  for k in pairs(tbl) do
    table.insert(keys, k)
  end

  table.sort(keys, function(a, b)
    local pa = priority[a] or 100
    local pb = priority[b] or 100
    if pa ~= pb then
      return pa < pb
    end
    return a < b
  end)

  return keys
end

function M.serialize(data, body)
  local lines = { FRONTMATTER_START }

  local sorted_keys = get_sorted_keys(data)

  for _, key in ipairs(sorted_keys) do
    local value = data[key]
    if type(value) == "table" then
      table.insert(lines, key .. ":")
      for _, item in ipairs(value) do
        table.insert(lines, "  - " .. tostring(item))
      end
    else
      table.insert(lines, key .. ": " .. serialize_value(value))
    end
  end

  table.insert(lines, FRONTMATTER_END)

  if body and body ~= "" then
    table.insert(lines, body)
  end

  return table.concat(lines, "\n")
end

function M.update(content, updates)
  local data, body = M.parse(content)
  if not data then
    data = {}
    body = content or ""
  end

  for k, v in pairs(updates) do
    data[k] = v
  end
  -- updates 側が旧キーを持ち込んでも書き戻さない
  normalize_legacy_keys(data)

  return M.serialize(data, body)
end

---ファイルの内容がvibing.nvimチャットファイルかどうかを判定
---フロントマターに`vibing.nvim: true`が含まれているかをチェック
---@param content string ファイルの内容
---@return boolean
function M.is_vibing_chat(content)
  if not content or content == "" then
    return false
  end

  local data, _ = M.parse(content)
  if not data then
    return false
  end

  return data["vibing.nvim"] == true
end

-- The closing `---` is looked for lazily instead of by reading a fixed window of
-- lines: a chat's frontmatter has no length bound (permission and orchestration
-- lists grow with use), and a fixed window silently reports everything past it as
-- a non-chat. That is how the original 50-line window broke codex chats, and
-- raising it to 200 only moved the cliff.
--
-- This ceiling is not that limit brought back. It is a runaway guard for a file
-- that opens with `---` and never closes it — a chat still being streamed, or an
-- unrelated file whose first line happens to match — so it sits far above any
-- frontmatter a chat can produce, and a real chat never reaches it.
--
-- What reaching it costs, since `is_vibing_chat_buffer` runs from `BufEnter` and
-- caches only positive results (measured over 2000 calls on a 5000-line buffer):
-- a file that opens with `---` and never closes takes 0.49ms per call against the
-- 0.05ms the old 200-line read took. A file whose frontmatter does close — every
-- ordinary Markdown article with YAML frontmatter — stops at its closing `---`
-- and takes 0.011ms, half what the fixed read cost, because the read is now
-- proportional to the frontmatter rather than to the window.
local FRONTMATTER_SCAN_CEILING = 2000

---frontmatter領域を先頭から閉じ`---`まで読む
---@param next_line fun(): string? 1行ずつ返すイテレータ(末尾でnil)
---@return string[]? lines 開始`---`から閉じ`---`まで(両端を含む)。閉じていなければnil
local function read_region(next_line)
  local first = next_line()
  if first == nil or trim(first) ~= FRONTMATTER_START then
    return nil
  end

  local region = { first }
  for _ = 2, FRONTMATTER_SCAN_CEILING do
    local line = next_line()
    if line == nil then
      return nil
    end
    table.insert(region, line)
    if trim(line) == FRONTMATTER_END then
      return region
    end
  end

  return nil
end

---バッファを一定行ずつ読む行イテレータを作る
---frontmatterを見るだけの用途でバッファ全体をコピーしないためにチャンク化する。
---チャットバッファは数千行に育つが、frontmatterは先頭の数十行しかない
---@param bufnr number
---@return fun(): string?
local function buffer_line_iterator(bufnr)
  local CHUNK_SIZE = 64
  local chunk, chunk_index, next_start = {}, 0, 0

  return function()
    chunk_index = chunk_index + 1
    if chunk_index > #chunk then
      chunk = vim.api.nvim_buf_get_lines(bufnr, next_start, next_start + CHUNK_SIZE, false)
      if #chunk == 0 then
        return nil
      end
      next_start = next_start + #chunk
      chunk_index = 1
    end
    return chunk[chunk_index]
  end
end

---バッファ先頭のfrontmatter領域を返す
---
---戻り値のindexはバッファの行番号(1始まり)とそのまま一致し、末尾要素が閉じ`---`になる。
---frontmatterを行単位で編集する側（`presentation/chat/modules/frontmatter_handler`）が
---固定行数を読むのをやめられるように公開している
---@param bufnr number バッファ番号
---@return string[]? lines 閉じ`---`まで(両端を含む)。frontmatterが無い/閉じていなければnil
function M.buffer_region(bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return nil
  end

  return read_region(buffer_line_iterator(bufnr))
end

---ファイルパスからvibing.nvimチャットファイルかどうかを判定
---@param file_path string ファイルパス
---@return boolean
function M.is_vibing_chat_file(file_path)
  if not file_path or file_path == "" then
    return false
  end

  if vim.fn.filereadable(file_path) ~= 1 then
    return false
  end

  -- `readfile()` cannot stop at a predicate — it takes a line count — so the file
  -- is read line by line and abandoned at the closing `---`.
  local file = io.open(file_path, "r")
  if not file then
    return false
  end

  local ok, region = pcall(read_region, file:lines())
  file:close()

  if not ok or not region then
    return false
  end

  return M.is_vibing_chat(table.concat(region, "\n"))
end

---ファイルパスがvibing.nvimのチャット保存ディレクトリ配下かどうかを判定
---内容（frontmatter）に依存しないため、ストリーミング途中や frontmatter 未完成の
---ファイルでも確実にチャットとして認識できる。project/user のデフォルト保存先を
---カバーする（custom save_dir は frontmatter 判定側で拾う）。
---@param file_path string? ファイルパス
---@return boolean
function M.is_vibing_chat_path(file_path)
  if not file_path or file_path == "" then
    return false
  end

  local normalized = vim.fn.fnamemodify(file_path, ":p"):gsub("\\", "/")
  -- project 保存先: <root>/.vibing/chat/ 、user 保存先: <data>/vibing/chats/
  if normalized:match("/%.vibing/chat/[^/]+%.md$") then
    return true
  end
  if normalized:match("/vibing/chats/[^/]+%.md$") then
    return true
  end

  return false
end

---バッファの内容がvibing.nvimチャットファイルかどうかを判定
---キャッシュを使用してパフォーマンスを最適化
---@param bufnr number バッファ番号
---@return boolean
function M.is_vibing_chat_buffer(bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return false
  end

  -- Check cache first (buffer-local variable)
  -- NOTE: only `true` is ever cached (see below), so a cached value is always a
  -- confirmed chat buffer.
  local cached = vim.b[bufnr].vibing_is_chat_buffer
  if cached == true then
    return true
  end

  -- Path-based detection first: files under the chat save directory are chats
  -- regardless of content. This is content-independent, so it works even while a
  -- buffer is still being streamed and its frontmatter is incomplete.
  if M.is_vibing_chat_path(vim.api.nvim_buf_get_name(bufnr)) then
    vim.b[bufnr].vibing_is_chat_buffer = true
    return true
  end

  -- Same rule as is_vibing_chat_file: read exactly the frontmatter, then let the
  -- parser answer. Deciding it with a regex here instead would give the two
  -- functions two different notions of what makes a file a chat.
  local region = M.buffer_region(bufnr)
  local is_chat = region ~= nil and M.is_vibing_chat(table.concat(region, "\n"))

  -- Only cache a positive result. Caching `false` would stick permanently while
  -- a buffer is still being streamed/written (incomplete frontmatter), because
  -- buffer-local vars survive `:edit` and nothing invalidates them — leaving a
  -- valid chat file unrecognized. A `false` here just means "re-check next time".
  if is_chat then
    vim.b[bufnr].vibing_is_chat_buffer = true
  end

  return is_chat
end

return M
