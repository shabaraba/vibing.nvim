local Frontmatter = require("vibing.infrastructure.storage.frontmatter")

---@class Vibing.Presentation.Chat.FrontmatterHandler
---バッファ先頭のfrontmatterを編集する。
---
---**行の切り貼りはしない**。frontmatter領域を `Frontmatter.parse` に通し、テーブルを
---書き換え、`Frontmatter.serialize_lines` で領域ごと書き戻す（#717）。以前はここに
---「1行1キー、リストは `  - value` が1行1要素」という独立したパーサーがあり、
---`Frontmatter` 側の実装と同じ入力に同じ答えを返す保証が無かった。入れ子（`orchestrated`
---のマップ要素）は行の切り貼りでは正しく扱えないので、統合はその前提でもある。
---
---領域の取得は `Frontmatter.buffer_region` で、閉じ `---` まで追う。固定行数の窓は
---frontmatterが伸びた瞬間に**黙って**失敗する — `parse` が空テーブルを返し、
---`update_field`/`update_list` が false を返し、`update_session_id` は何も書かずに
---セッションIDを失う。
local M = {}

---frontmatter領域を読んで書き換え、必要なら書き戻す
---@param buf number
---@param mutate fun(data: table): boolean? falseを返すと書き戻さない
---@return boolean success
local function rewrite(buf, mutate)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return false
  end

  local region = Frontmatter.buffer_region(buf)
  if not region then
    return false
  end

  local data = Frontmatter.parse(table.concat(region, "\n"))
  if not data then
    return false
  end

  if mutate(data) == false then
    return false
  end

  local lines = Frontmatter.serialize_lines(data)
  -- 変化が無ければ触らない。書き戻すだけでバッファは modified になり、チャットの保存が
  -- 走る（`orchestration_link` が同じリンクを2度書く経路がまさにこれ）
  if not vim.deep_equal(lines, region) then
    vim.api.nvim_buf_set_lines(buf, 0, #region, false, lines)
  end

  return true
end

---@return string
local function now()
  return os.date("%Y-%m-%dT%H:%M:%S") --[[@as string]]
end

---フロントマターをパース
---@param buf number バッファ番号
---@return table<string, string|string[]|number|boolean>
function M.parse(buf)
  local region = Frontmatter.buffer_region(buf)
  if not region then
    return {}
  end

  return Frontmatter.parse(table.concat(region, "\n")) or {}
end

---session_idを更新
---
---キーが無ければ**足さない**。session_idを持たないファイルはチャットとして生まれた
---ものではないので、そこに書き込む相手を間違えている
---@param buf number バッファ番号
---@param session_id string セッションID
function M.update_session_id(buf, session_id)
  rewrite(buf, function(data)
    if data.session_id == nil then
      return false
    end
    data.session_id = session_id
  end)
end

---フロントマターのフィールドを更新または追加
---@param buf number バッファ番号
---@param key string キー
---@param value string? nilならフィールドを削除
---@param update_timestamp? boolean タイムスタンプを更新するか
---@return boolean success
function M.update_field(buf, key, value, update_timestamp)
  if not key or key == "" then
    return false
  end

  return rewrite(buf, function(data)
    -- 旧綴りの行は `Frontmatter.parse` が正式なキーへ寄せて落とすので、1つのfrontmatterに
    -- 同じ設定が二重に並ぶ状態はここを通るだけで解消する
    data[key] = value
    if value ~= nil and update_timestamp ~= false and key ~= "updated_at" then
      data.updated_at = now()
    end
  end)
end

---リスト要素の同一性。スカラーもマップ要素（`orchestrated`）も同じ規則で比べる
---@param a any
---@param b any
---@return boolean
local function same_item(a, b)
  return vim.deep_equal(a, b)
end

---@param value any
---@return boolean
local function is_empty_value(value)
  if value == nil then
    return true
  end
  if type(value) == "string" then
    return value == ""
  end
  if type(value) == "table" then
    return next(value) == nil
  end
  return false
end

---フロントマターのリストフィールドを更新（追加/削除）
---@param buf number バッファ番号
---@param key string フィールド名
---@param value string|table 追加/削除する要素
---@param action "add"|"remove" 操作種別
---@return boolean success
function M.update_list(buf, key, value, action)
  if not key or key == "" or is_empty_value(value) then
    return false
  end

  return rewrite(buf, function(data)
    local items = {}
    for _, item in ipairs(Frontmatter.as_list(data[key])) do
      if action ~= "remove" or not same_item(item, value) then
        table.insert(items, item)
      end
    end

    if action == "add" then
      local exists = false
      for _, item in ipairs(items) do
        if same_item(item, value) then
          exists = true
          break
        end
      end
      if not exists then
        table.insert(items, value)
      end
    end

    -- 空になったキーは行ごと落とす。値の無い `orchestrated:` を残しても意味は同じだが、
    -- 使われていないリンクの見出しが残り続ける
    data[key] = #items > 0 and items or nil
    data.updated_at = now()
  end)
end

---フロントマターのリストフィールドを取得
---@param buf number バッファ番号
---@param key string フィールド名
---@return (string|table)[] items
function M.get_list(buf, key)
  local frontmatter = M.parse(buf)
  return Frontmatter.as_list(frontmatter[key])
end

return M
