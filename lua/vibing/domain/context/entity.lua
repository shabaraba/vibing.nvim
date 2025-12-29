---@class Vibing.Domain.Context
---コンテキストエンティティ
---ファイルや選択範囲のコンテキスト情報を表現
local Context = {}
Context.__index = Context

---@alias Vibing.ContextType "file"|"selection"|"buffer"

---新しいコンテキストを作成
---@param type Vibing.ContextType コンテキストタイプ
---@param path string? ファイルパス
---@param content string コンテンツ
---@return Vibing.Domain.Context
function Context:new(type, path, content)
  local instance = setmetatable({}, self)
  instance.type = type
  instance.path = path
  instance.content = content
  instance.start_line = nil
  instance.end_line = nil
  instance.bufnr = nil
  return instance
end

---選択範囲付きコンテキストを作成
---@param path string ファイルパス
---@param content string コンテンツ
---@param start_line number 開始行
---@param end_line number 終了行
---@return Vibing.Domain.Context
function Context:new_selection(path, content, start_line, end_line)
  local instance = self:new("selection", path, content)
  instance.start_line = start_line
  instance.end_line = end_line
  return instance
end

---バッファコンテキストを作成
---@param bufnr number バッファ番号
---@param content string コンテンツ
---@return Vibing.Domain.Context
function Context:new_buffer(bufnr, content)
  local instance = self:new("buffer", nil, content)
  instance.bufnr = bufnr
  return instance
end

---@file:path形式の文字列に変換
---@return string
function Context:to_reference()
  if self.type == "selection" and self.start_line and self.end_line then
    return string.format("@file:%s:L%d-L%d", self.path, self.start_line, self.end_line)
  elseif self.path then
    return string.format("@file:%s", self.path)
  else
    return string.format("@buffer:%d", self.bufnr or 0)
  end
end

---コンテキストが空かチェック
---@return boolean
function Context:is_empty()
  return self.content == nil or self.content == ""
end

return Context
