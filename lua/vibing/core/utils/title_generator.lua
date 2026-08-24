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

---タイトルの体裁に関する共通ルール。入力が抜粋でも summary でも変わらない部分。
---@param lang_name string?
---@return string[]
local function format_rules(lang_name)
  local rules = {
    "- Be specific: name the feature, bug, file, or component involved.",
    "- 30 characters maximum.",
    "- No date, no file extension, no quotes, no surrounding punctuation.",
  }
  if lang_name then
    rules[#rules + 1] = "- Write the title in " .. lang_name .. "."
  end
  return rules
end

---@param lead string[] 入力の説明と主題の取り方（入力の種類ごとに違う部分）
---@param lang_name string?
---@return string
local function build_instruction(lead, lang_name)
  local lines = vim.list_extend(vim.deepcopy(lead), format_rules(lang_name))
  lines[#lines + 1] = ""
  lines[#lines + 1] = "Respond with ONLY the title, nothing else."
  return table.concat(lines, "\n")
end

-- 抜粋入力。「主題 = ユーザーが達成しようとしたこと」を明示する。これを言わないと、モデルは
-- 抜粋の末尾（マージ・クリーンアップ等の後始末）や実行したコマンドをタイトルにしてしまう。
local EXCERPT_LEAD = {
  "The text above is an excerpt of a conversation between a user and an AI coding assistant.",
  "",
  "Write a title naming WHAT THE USER WAS TRYING TO ACCOMPLISH across the whole conversation.",
  "",
  "Rules:",
  "- The subject comes from the user's requests, not from the assistant's replies.",
  "- Do not title it after the last step, the wrap-up work, or the tools and commands that were run.",
}

-- summary 入力。抜粋固有の防御（主題は user 側から / 末尾に引きずられるな）はここでは不要で、
-- 代わりに summary 自身の構成（`### 一行要約` / `### 決定事項` が主題、`### やったこと` と
-- `### 未解決 / 次の一手` は主題ではない）に沿った取り方を指示する。
-- 見出し名を直接は書かない: `prompts/chat_summary.md` のテンプレートを変えたときに、
-- ここが黙って古い見出しを指し続けるのを避けるため。
local SUMMARY_LEAD = {
  "The text above is a summary of a conversation between a user and an AI coding assistant.",
  "",
  "Write a title naming WHAT THE CONVERSATION WAS ABOUT.",
  "",
  "Rules:",
  "- The subject is the one-line overview and the decisions, not the file-by-file work log.",
  "- Do not title it after the open questions, the next steps, or the files that were touched.",
}

---会話履歴からAIにタイトルを生成させる
---
---入力は2種類ある。`opts.summary`（`:VibingSummarize` がバッファに書いた `## summary`）が
---あればそれを使い、無ければ会話の抜粋（`chat_excerpt` がツール実況を落として user 発言中心に
---組み立てたもの）にフォールバックする。summary を優先するのは、それが既に「会話全体で
---何をしたか」に圧縮されていて、長い会話でも主題を外しにくく、送るテキストも短いため。
---
---どちらの場合もセッションの resume/fork は行わない（全履歴を読み込んで context を超過し
---"Prompt is too long" になるのを避けるため）。都度フレッシュに送るだけなので session_id は不要。
---@param conversation {role: string, content: string}[] 会話履歴
---@param callback fun(title: string?, error: string?) 結果コールバック
---@param adapter table? タイトル生成に使うアダプタ。省略時はグローバル既定を使う。
---@param opts {summary: string?}? summary があれば抜粋の代わりにそれを入力にする
function M.generate_from_conversation(conversation, callback, adapter, opts)
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

  local summary = opts and opts.summary
  if summary == "" then
    summary = nil
  end

  local input = summary or chat_excerpt.build(conversation)
  local title_instruction = build_instruction(summary and SUMMARY_LEAD or EXCERPT_LEAD, lang_name)

  -- Title generation is a lightweight utility call: no tools/CLAUDE.md/MCP needed
  local stream_opts = {
    lightweight = true,
  }

  -- Always send a bounded input as a fresh prompt (no resume/fork), so long
  -- chats never exceed the context window.
  local prompt = input .. "\n\n" .. title_instruction

  local collected_response = ""

  adapter:stream(prompt, stream_opts, function(chunk)
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
