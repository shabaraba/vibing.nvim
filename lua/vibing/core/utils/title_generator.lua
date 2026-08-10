---Title generation utilities
---@class Vibing.Utils.TitleGenerator
---会話内容からAIを使用してタイトルを生成するユーティリティ
---:VibingSetFileTitleコマンドで使用
local M = {}

local filename_util = require("vibing.core.utils.filename")
local language_utils = require("vibing.core.utils.language")

-- Title generation only needs the gist of the conversation. Sending the whole
-- history (or resuming/forking the full session) makes long chats fail with
-- "Prompt is too long", so we build a bounded excerpt instead.
-- Keep per-message and tail sizes small enough that first + tail comfortably fit
-- under MAX_TOTAL_CHARS, so the final safety-net truncation never drops the most
-- recent message (which matters most for the title).
local MAX_MESSAGE_CHARS = 800
local TAIL_MESSAGE_COUNT = 4
local MAX_TOTAL_CHARS = 6000

---@param s string
---@param n integer
---@return string
local function truncate(s, n)
  if #s > n then
    return s:sub(1, n) .. "…"
  end
  return s
end

---会話から「最初のユーザーメッセージ＋末尾数メッセージ」の抜粋を作る。
---各メッセージと全体の両方に上限を設け、長い会話でも context を超えないようにする。
---@param conversation {role: string, content: string}[]
---@return string
local function build_excerpt(conversation)
  local selected
  if #conversation <= TAIL_MESSAGE_COUNT + 1 then
    selected = conversation
  else
    selected = {}
    -- 最初のユーザーメッセージでトピックを固定
    for _, msg in ipairs(conversation) do
      if msg.role == "user" then
        selected[#selected + 1] = msg
        break
      end
    end
    -- 直近の文脈
    for i = #conversation - TAIL_MESSAGE_COUNT + 1, #conversation do
      selected[#selected + 1] = conversation[i]
    end
  end

  local parts = {}
  for _, msg in ipairs(selected) do
    parts[#parts + 1] = string.format("[%s]: %s", msg.role, truncate(msg.content or "", MAX_MESSAGE_CHARS))
  end
  return truncate(table.concat(parts, "\n\n"), MAX_TOTAL_CHARS)
end

---会話履歴からAIにタイトルを生成させる
---会話の抜粋（最初のユーザーメッセージ＋末尾数メッセージ、各上限付き）をアダプタに送り、
---簡潔なファイル名用タイトルを生成する。結果はコールバックで非同期に返される。
---セッションの resume/fork は行わない（全履歴を読み込んで context を超過し
---"Prompt is too long" になるのを避けるため）。そのため session_id は使用しない。
---@param conversation {role: string, content: string}[] 会話履歴
---@param callback fun(title: string?, error: string?) 結果コールバック
---@param session_id string? 後方互換のため受け取るが未使用（resume/forkは廃止）
---@param adapter table? タイトル生成に使うアダプタ。省略時はグローバル既定を使う。
function M.generate_from_conversation(conversation, callback, session_id, adapter)
  local _ = session_id -- 後方互換で受け取るのみ（resume/fork廃止のため未使用）
  if not conversation or #conversation == 0 then
    callback(nil, "No conversation to generate title from")
    return
  end

  local vibing = require("vibing")
  adapter = adapter or vibing.get_adapter()
  local config = vibing.get_config()

  if not adapter then
    callback(nil, "No adapter configured")
    return
  end

  local lang_code = language_utils.get_language_code(config.language, "chat")
  local lang_name = lang_code and language_utils.language_names[lang_code]
  local lang_instruction = lang_name and ("Generate the title in " .. lang_name .. ". ") or ""

  local title_instruction = "Based on the above conversation, generate a concise title (maximum 30 characters) that summarizes the main topic. "
    .. lang_instruction
    .. "The title should be suitable for a filename. "
    .. "Respond with ONLY the title, nothing else."

  -- Title generation is a lightweight utility call: no tools/CLAUDE.md/MCP needed
  local opts = {
    lightweight = true,
  }

  -- Always send a bounded excerpt as a fresh prompt (no resume/fork), so long
  -- chats never exceed the context window.
  local prompt = build_excerpt(conversation) .. "\n\n" .. title_instruction

  local collected_response = ""

  adapter:stream(prompt, opts, function(chunk)
    collected_response = collected_response .. chunk
  end, function(response)
    if response.error then
      callback(nil, response.error)
      return
    end

    local title = collected_response
    if title == "" and response.content then
      title = response.content
    end

    title = vim.trim(title)

    -- デバッグ: AIの生成結果をログ出力
    vim.notify(string.format("[vibing] AI generated title: '%s'", title), vim.log.levels.DEBUG)

    title = filename_util.sanitize(title)

    -- デバッグ: サニタイズ後の結果をログ出力
    vim.notify(string.format("[vibing] Sanitized title: '%s'", title), vim.log.levels.DEBUG)

    if title == "" then
      -- 空の場合はフォールバック
      title = "untitled"
      vim.notify("[vibing] Title was empty after sanitization, using fallback 'untitled'", vim.log.levels.WARN)
    end

    callback(title, nil)
  end)
end

return M
