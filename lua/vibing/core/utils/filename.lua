---Filename generation utilities
---@class Vibing.Utils.Filename
---チャットファイルのファイル名生成ユーティリティ
---メッセージ内容から意味のあるファイル名を自動生成
local M = {}

---テキストをファイル名として安全な文字列に変換
---小文字化、特殊文字削除、連続アンダースコア圧縮、長さ制限を実施
---@param text string 変換元のテキスト（通常は最初のユーザーメッセージ）
---@return string sanitized_text サニタイズ済みのファイル名用文字列（最大32文字）
function M.sanitize(text)
  -- 小文字に変換
  text = text:lower()
  -- 空白とハイフンをアンダースコアに
  text = text:gsub("[%s%-]+", "_")
  -- ファイル名に使えない文字を削除
  text = text:gsub("[^%w_%-]", "")
  -- 連続するアンダースコアを1つに
  text = text:gsub("_+", "_")
  -- 先頭と末尾のアンダースコアを削除
  text = text:gsub("^_+", ""):gsub("_+$", "")
  -- 最大32文字に制限
  if #text > 32 then
    text = text:sub(1, 32)
  end
  return text
end

---会話の最初のメッセージからファイル名を生成
---メッセージの最初の行（最大50文字）をサニタイズしてトピック名として使用
---形式: YYYYMMDD_トピック (例: 20240101_fix_authentication_bug)
---メッセージが空またはサニタイズ後に空文字列の場合はタイムスタンプのみ
---@param message string 最初のユーザーメッセージ
---@return string filename YYYYMMDD_topic 形式のファイル名（拡張子なし）
function M.generate_from_message(message)
  if not message or message == "" then
    return os.date("chat_%Y%m%d_%H%M%S")
  end

  -- 最初の行または最初の50文字を取得
  local first_line = message:match("^([^\n]+)") or message
  if #first_line > 50 then
    first_line = first_line:sub(1, 50)
  end

  -- サニタイズしてトピック名を生成
  local topic = M.sanitize(first_line)

  -- トピックが空の場合はタイムスタンプのみ
  if topic == "" then
    return os.date("chat_%Y%m%d_%H%M%S")
  end

  -- YYYYMMDD_topic形式
  return os.date("%Y%m%d") .. "_" .. topic
end

---タイムスタンプベースのデフォルトファイル名を生成
---形式: chat_YYYYMMDD_HHMMSS (例: chat_20240101_153045)
---メッセージからファイル名を生成できない場合のフォールバック
---@return string filename タイムスタンプ形式のファイル名（拡張子なし）
function M.generate_default()
  return os.date("chat_%Y%m%d_%H%M%S")
end

---AIが生成したタイトルからファイル名を生成
---形式: {type}-yyyymmdd-HHmm-{title}.vibing (例: chat-20250627-1430-fix_auth_bug.vibing)
---:VibingSetFileTitleコマンドで使用
---@param title string AIが生成したタイトル（サニタイズ前）
---@param file_type "chat"|"inline" ファイルタイプ
---@return string filename 完全なファイル名（拡張子付き）
function M.generate_with_title(title, file_type)
  file_type = file_type or "chat"
  local sanitized = M.sanitize(title)

  if sanitized == "" then
    sanitized = "untitled"
  end

  local timestamp = os.date("%Y%m%d-%H%M")
  return string.format("%s-%s-%s.vibing", file_type, timestamp, sanitized)
end

return M
