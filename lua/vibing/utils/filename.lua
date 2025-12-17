---Filename generation utilities
local M = {}

---ファイル名として安全な文字列に変換
---@param text string
---@return string
local function sanitize(text)
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

---会話内容からファイル名を生成
---@param message string 最初のユーザーメッセージ
---@return string filename
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
  local topic = sanitize(first_line)

  -- トピックが空の場合はタイムスタンプのみ
  if topic == "" then
    return os.date("chat_%Y%m%d_%H%M%S")
  end

  -- YYYYMMDD_topic形式
  return os.date("%Y%m%d") .. "_" .. topic
end

---デフォルトのファイル名を生成
---@return string filename
function M.generate_default()
  return os.date("chat_%Y%m%d_%H%M%S")
end

return M
