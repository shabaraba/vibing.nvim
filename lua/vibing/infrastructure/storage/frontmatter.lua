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

local function serialize_value(value)
  if type(value) == "boolean" then
    return value and "true" or "false"
  elseif type(value) == "number" then
    return tostring(value)
  else
    return tostring(value)
  end
end

local function get_sorted_keys(tbl)
  local keys = {}
  for k in pairs(tbl) do
    table.insert(keys, k)
  end

  local priority = {
    ["vibing.nvim"] = 1,
    session_id = 2,
    created_at = 3,
    forked_from = 4,
    subagent_id = 5,
    -- 出自を示すフィールド(forked_from / subagent_id)の直後。どれも「このチャットが
    -- 他のどのチャットと繋がっているか」を答えるものなので、まとめて先頭側に置く
    orchestrated = 6,
    orchestrated_by = 7,
    working_dir = 8,
    agent = 9,
    model = 10,
    effort = 11,
    permission_mode = 12,
    permissions_allow = 13,
    permissions_deny = 14,
    permissions_ask = 15,
    language = 16,
  }

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

  -- Scan lines until frontmatter close to handle any frontmatter length
  local MAX_FRONTMATTER_LINES = 200
  local lines = vim.fn.readfile(file_path, "", MAX_FRONTMATTER_LINES)
  if #lines < 2 or trim(lines[1]) ~= FRONTMATTER_START then
    return false
  end

  local found_vibing = false
  for i = 2, #lines do
    if trim(lines[i]) == FRONTMATTER_END then
      return found_vibing
    end
    if lines[i]:match("^vibing%.nvim:%s*true") then
      found_vibing = true
    end
  end

  return false
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

  -- Read enough lines to cover the whole frontmatter, matching is_vibing_chat_file.
  -- 50 lines was not enough for chats with long permission arrays (e.g. codex
  -- sessions), where the closing `---` can sit well past line 50.
  local MAX_FRONTMATTER_LINES = 200
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, MAX_FRONTMATTER_LINES, false)
  local content = table.concat(lines, "\n")
  local is_chat = M.is_vibing_chat(content)

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
