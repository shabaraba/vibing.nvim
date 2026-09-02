---タイムスタンプユーティリティ
---チャットセクションのヘッダーを組み立て・分解する。
---
---ヘッダーの文法はこの1ファイルにしかない: `## <Kind> <!-- <stamp>[ from <path>] -->`。
---`Kind` は `User` / `Assistant` に加えて、他のチャットから配達されたものを表す
---`Request` / `Report` / `Notice`（#657 の押し出し型報告）。`stamp` は `unsent` か
---タイムスタンプで、`from` は送信元のチャットファイルのパス。
---
---**配達セクションも `extract_role` は "user" を返す。** セクションの中身はそのまま CLI へ送る
---プロンプトなので（`conversation_extractor.extract_user_message`）、別ロールにすると
---送信・会話抽出・デイリーサマリ・ジャンプの各所を個別に教育することになり、どれか1つ
---忘れた時点で「配達されたターンが送信されない」＝報告が黙って消える側に倒れる。見た目を
---分けたいだけなので、区別は `parse_header().kind` を見る側の仕事にしてある。

---@class Vibing.Utils.Timestamp
local M = {}

-- タイムスタンプフォーマット定数
local TIMESTAMP_FORMAT = "%Y-%m-%d %H:%M:%S"
-- タイムスタンプパターン（正規表現）
local TIMESTAMP_PATTERN = "%d%d%d%d%-%d%d%-%d%d %d%d:%d%d:%d%d"
-- レガシーヘッダーパターン（タイムスタンプなし）
local LEGACY_HEADER_PATTERN = "^## (%w+)"

---他のチャットから配達されたセクションの種別
---
---`Request` は配布（オーケストレーター→ワーカー）、`Report` は報告・返答（その逆向き）、
---`Notice` は vibing.nvim 自身が出す watchdog 通知。どちらの向きかは
---`orchestration_link.direction` が frontmatter の記録から決める
---@type table<string, boolean>
local DELIVERY_KINDS = { Request = true, Report = true, Notice = true }

---現在時刻のタイムスタンプを生成
---フォーマット: "YYYY-MM-DD HH:MM:SS"
---@return string timestamp フォーマット済みタイムスタンプ文字列
function M.now()
  local timestamp = os.date(TIMESTAMP_FORMAT)
  if not timestamp then
    -- os.date()が失敗した場合（極めて稀だが可能性はある）
    vim.notify("[vibing] Failed to generate timestamp - using fallback", vim.log.levels.WARN)
    -- フォールバック: エポック秒を使用
    return string.format("UNKNOWN-%d", os.time())
  end
  return timestamp
end

---@class Vibing.Utils.Timestamp.Header
---@field kind string "User" | "Assistant" | "Request" | "Report" | "Notice"
---@field unsent boolean 送信前のマーカー（`<!-- unsent -->`）か
---@field timestamp string? 送信済みなら記録された時刻
---@field from string? 配達セクションの送信元チャットのパス

---ヘッダー行を分解する（ヘッダーでなければ nil）
---
---読めない `<!-- ... -->` の中身は**種別を捨てずに**受け入れる。ここは表示のための分解で、
---壊れたコメント1つでセクションそのものが行方不明になるほうが害が大きい
---@param line string
---@return Vibing.Utils.Timestamp.Header?
function M.parse_header(line)
  local kind, meta = line:match("^## (%a+) <!%-%- (.-) %-%->%s*$")
  if kind then
    if kind ~= "User" and kind ~= "Assistant" and not DELIVERY_KINDS[kind] then
      return nil
    end

    local stamp, from = meta:match("^(.-) from (.+)$")
    stamp = stamp or meta
    local unsent = stamp == "unsent"
    return {
      kind = kind,
      unsent = unsent,
      timestamp = (not unsent and stamp:match("^" .. TIMESTAMP_PATTERN .. "$")) and stamp or nil,
      from = from,
    }
  end

  -- レガシーパターン（シンプルヘッダー）: "## User" or "## Assistant"
  local legacy = line:match(LEGACY_HEADER_PATTERN)
  if legacy == "User" or legacy == "Assistant" then
    return { kind = legacy, unsent = false }
  end

  return nil
end

---ヘッダー行からロールを抽出（HTMLコメント形式/レガシー対応）
---@param line string ヘッダー行
---@return string? role "user" | "assistant" | nil（ヘッダーでない場合はnil）
function M.extract_role(line)
  local header = M.parse_header(line)
  if not header then
    return nil
  end
  return header.kind == "Assistant" and "assistant" or "user"
end

---行がメッセージヘッダーかどうかチェック
---@param line string チェック対象の行
---@return boolean is_header ヘッダーの場合true
function M.is_header(line)
  return M.parse_header(line) ~= nil
end

---未送信ユーザーヘッダーを作成
---送信前の一時的なマーカーとして使用され、送信時にタイムスタンプ付きヘッダーに置き換えられる
---@return string header 未送信ユーザーヘッダー（例: "## User <!-- unsent -->"）
function M.create_unsent_user_header()
  return "## User <!-- unsent -->"
end

---タイムスタンプ付きユーザーヘッダーを作成（HTMLコメント形式）
---@param timestamp? string オプションのタイムスタンプ（省略時は現在時刻）
---@return string header タイムスタンプ付きヘッダー（例: "## User <!-- 2025-12-29 14:30:55 -->"）
function M.create_user_header_with_timestamp(timestamp)
  timestamp = timestamp or M.now()
  return string.format("## User <!-- %s -->", timestamp)
end

---配達セクションのヘッダーを作成
---
---`stamp` を渡し分ける形にしてあるのは、配達も `## User` と同じ「未送信で書いて、送信時に
---コミットする」流れに乗るため。リミット中の予約（`auto_resume`）は未送信セクションが
---そのまま残っていることを前提にしているので、そこだけ直接タイムスタンプを書くわけには
---いかない
---@param kind string "Request" | "Report" | "Notice"
---@param from string? 送信元チャットの表示パス（合流した配達など、特定できないときは nil）
---@param stamp string? タイムスタンプ（省略時は `unsent`）
---@return string header
function M.create_delivery_header(kind, from, stamp)
  if not DELIVERY_KINDS[kind] then
    error(string.format("Unknown delivery kind: %s", tostring(kind)))
  end

  local meta = stamp or "unsent"
  if from and from ~= "" then
    meta = meta .. " from " .. from
  end
  return string.format("## %s <!-- %s -->", kind, meta)
end

---行が未送信ヘッダー（`## User` / 配達セクションのどちらでも）かどうか
---@param line string
---@return boolean
function M.is_unsent_header(line)
  local header = M.parse_header(line)
  return header ~= nil and header.unsent
end

---行が他のチャットからの配達セクションのヘッダーかどうか
---@param line string
---@return boolean
function M.is_delivery_header(line)
  local header = M.parse_header(line)
  return header ~= nil and DELIVERY_KINDS[header.kind] == true
end

---行が未送信ユーザーヘッダーかどうかチェック
---@param line string チェック対象の行
---@return boolean is_unsent 未送信ヘッダーの場合true
function M.is_unsent_user_header(line)
  return line:match("^## User <!%-%- unsent %-%->$") ~= nil
end

---行がタイムスタンプ付きユーザーヘッダー（HTMLコメント形式）かどうかチェック
---@param line string チェック対象の行
---@return boolean is_timestamped タイムスタンプ付きヘッダーの場合true
function M.is_timestamped_user_header(line)
  return line:match("^## User <!%-%- " .. TIMESTAMP_PATTERN .. " %-%->$") ~= nil
end

---ヘッダーからタイムスタンプを抽出（HTMLコメント形式）
---@param line string タイムスタンプ付きヘッダー行
---@return string? timestamp タイムスタンプ文字列（存在しない場合はnil）
function M.extract_timestamp_from_comment(line)
  local header = M.parse_header(line)
  if not header or header.kind == "Assistant" then
    return nil
  end
  return header.timestamp
end

return M
