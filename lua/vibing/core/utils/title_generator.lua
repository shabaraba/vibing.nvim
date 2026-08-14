---Title generation utilities
---@class Vibing.Utils.TitleGenerator
---会話内容からAIを使用してタイトルを生成するユーティリティ
---:VibingSetFileTitleコマンドで使用
local M = {}

local filename_util = require("vibing.core.utils.filename")
local language_utils = require("vibing.core.utils.language")
local chat_excerpt = require("vibing.core.utils.chat_excerpt")

---AI応答から「タイトルとして使える最初の1行」を取り出す。
---ツール実況行（⏺ ToolSearch(...) 等）や空行を飛ばし、最初の意味のあるテキスト行を返す。
---これによりモデルがタイトル以外を返しても、複数行のゴミがそのままファイル名になるのを防ぐ。
---軽量呼び出しでツールは無効化しているが、それが破れたときの防御として残している。
---ツール行の判定は抜粋クリーニングと同じ `chat_excerpt` のものを使う（二重定義を作らないため）。
---@param text string
---@return string
local function first_title_line(text)
  for _, line in ipairs(vim.split(text or "", "\n", { plain = true })) do
    local trimmed = vim.trim(line)
    if trimmed ~= "" and not chat_excerpt.is_tool_line(trimmed) then
      return trimmed
    end
  end
  return vim.trim((text or ""):match("^([^\n]*)") or "")
end

---会話履歴からAIにタイトルを生成させる
---会話の抜粋（`chat_excerpt` がツール実況を落として user 発言中心に組み立てたもの）を
---アダプタに送り、簡潔なファイル名用タイトルを生成する。結果はコールバックで非同期に返される。
---セッションの resume/fork は行わない（全履歴を読み込んで context を超過し
---"Prompt is too long" になるのを避けるため）。抜粋を都度フレッシュに送るだけなので session_id は不要。
---@param conversation {role: string, content: string}[] 会話履歴
---@param callback fun(title: string?, error: string?) 結果コールバック
---@param adapter table? タイトル生成に使うアダプタ。省略時はグローバル既定を使う。
function M.generate_from_conversation(conversation, callback, adapter)
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

  -- 「主題 = ユーザーが達成しようとしたこと」を明示する。これを言わないと、モデルは
  -- 抜粋の末尾（マージ・クリーンアップ等の後始末）や実行したコマンドをタイトルにしてしまう。
  local lines = {
    "The text above is an excerpt of a conversation between a user and an AI coding assistant.",
    "",
    "Write a title naming WHAT THE USER WAS TRYING TO ACCOMPLISH across the whole conversation.",
    "",
    "Rules:",
    "- The subject comes from the user's requests, not from the assistant's replies.",
    "- Do not title it after the last step, the wrap-up work, or the tools and commands that were run.",
    "- Be specific: name the feature, bug, file, or component involved.",
    "- 30 characters maximum.",
    "- No date, no file extension, no quotes, no surrounding punctuation.",
  }
  if lang_name then
    lines[#lines + 1] = "- Write the title in " .. lang_name .. "."
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "Respond with ONLY the title, nothing else."
  local title_instruction = table.concat(lines, "\n")

  -- Title generation is a lightweight utility call: no tools/CLAUDE.md/MCP needed
  local opts = {
    lightweight = true,
  }

  -- Always send a bounded excerpt as a fresh prompt (no resume/fork), so long
  -- chats never exceed the context window.
  local prompt = chat_excerpt.build(conversation) .. "\n\n" .. title_instruction

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

    -- 防御: モデルがタイトル以外（narration やツール実況）を返しても、
    -- 最初の意味のある1行だけをタイトルにする。複数行がそのままファイル名になるのを防ぐ。
    title = first_title_line(title)

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
