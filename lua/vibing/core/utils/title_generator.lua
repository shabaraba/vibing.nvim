---Title generation utilities
---@class Vibing.Utils.TitleGenerator
---会話内容からAIを使用してタイトルを生成するユーティリティ
---:VibingSetFileTitleコマンドで使用
local M = {}

local filename_util = require("vibing.core.utils.filename")
local language_utils = require("vibing.core.utils.language")

---会話履歴からAIにタイトルを生成させる
---Claudeに会話全体を送信し、簡潔なファイル名用タイトルを生成
---結果はコールバックで非同期に返される
---session_idが渡された場合は --resume --fork-session で履歴をプロンプトキャッシュ参照させ、
---履歴の平文再送を避ける（新規セッションでのフルプライス送信を防ぐ）。省略時は従来通り
---会話全文をプロンプトに連結してフォールバックする。
---@param conversation {role: string, content: string}[] 会話履歴
---@param callback fun(title: string?, error: string?) 結果コールバック
---@param session_id string? 対象チャットのセッションID（あればfork-sessionで再利用）
function M.generate_from_conversation(conversation, callback, session_id)
  if not conversation or #conversation == 0 then
    callback(nil, "No conversation to generate title from")
    return
  end

  local vibing = require("vibing")
  local adapter = vibing.get_adapter()
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

  -- Use default permissions from config
  local opts = {
    permission_mode = config.permissions and config.permissions.mode or "acceptEdits",
    permissions_allow = config.permissions and config.permissions.allow or {},
    permissions_deny = config.permissions and config.permissions.deny or {},
  }

  local prompt
  if session_id and session_id ~= "" then
    prompt = title_instruction
    opts._session_id = session_id
    opts._session_id_explicit = true
    opts._is_fork = true
  else
    local conversation_text = {}
    for _, msg in ipairs(conversation) do
      table.insert(conversation_text, string.format("[%s]: %s", msg.role, msg.content))
    end
    prompt = table.concat(conversation_text, "\n\n") .. "\n\n" .. title_instruction
  end

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
