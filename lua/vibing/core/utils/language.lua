---@class Vibing.Utils.Language
---言語設定ユーティリティ
---言語コードから言語名への変換、プロンプトへの言語指示追加を提供
local M = {}

---言語コードから言語名へのマッピング
---ISO 639-1 コードをサポート
---@type table<string, string>
M.language_names = {
  ja = "Japanese",
  en = "English",
  zh = "Chinese",
  ko = "Korean",
  fr = "French",
  de = "German",
  es = "Spanish",
  it = "Italian",
  pt = "Portuguese",
  ru = "Russian",
  ar = "Arabic",
  hi = "Hindi",
  nl = "Dutch",
  sv = "Swedish",
  no = "Norwegian",
  da = "Danish",
  fi = "Finnish",
  pl = "Polish",
  tr = "Turkish",
  vi = "Vietnamese",
  th = "Thai",
}

---言語コードから言語指示文字列を生成
---@param lang_code string? 言語コード（例: "ja", "en"）
---@return string 言語指示（例: "in Japanese"）または空文字列
function M.get_language_instruction(lang_code)
  if not lang_code or lang_code == "" or lang_code == "en" then
    return ""
  end

  local lang_name = M.language_names[lang_code]
  if not lang_name then
    return ""
  end

  return " in " .. lang_name
end

---プロンプトに言語指示を追加
---プロンプトの末尾に言語指示を付加（コロンの前に挿入）
---@param prompt string 元のプロンプト
---@param lang_code string? 言語コード
---@return string 言語指示付きプロンプト
function M.add_language_instruction(prompt, lang_code)
  local instruction = M.get_language_instruction(lang_code)
  if instruction == "" then
    return prompt
  end

  -- プロンプトの末尾がコロンで終わる場合、コロンの前に言語指示を挿入
  if prompt:match(":$") then
    return prompt:sub(1, -2) .. instruction .. ":"
  else
    -- それ以外の場合は末尾に追加
    return prompt .. instruction
  end
end

---設定から言語コードを取得
---language が文字列の場合はそのまま返し、テーブルの場合は action_type に応じて適切な値を返す
---@param language string|Vibing.LanguageConfig|nil 言語設定
---@param action_type "chat"|"inline" アクションタイプ
---@return string? 言語コード
function M.get_language_code(language, action_type)
  if not language then
    return nil
  end

  -- 文字列の場合はそのまま返す
  if type(language) == "string" then
    return language
  end

  -- テーブルの場合は action_type に応じて返す
  if type(language) == "table" then
    local code = language[action_type] or language.default
    return code
  end

  return nil
end

return M
