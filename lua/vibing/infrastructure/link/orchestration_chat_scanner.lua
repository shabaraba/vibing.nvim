---@class Vibing.Infrastructure.Link.OrchestrationChatScanner : Vibing.Infrastructure.Link.Scanner
---オーケストレーションで結ばれたチャットの `orchestrated` / `orchestrated_by` を
---ファイル名の変更に追従させるスキャナー。
---
---`ForkedChatScanner` が雛形だが、そのままコピーはできない。`forked_from` はスカラーなので
---`Frontmatter.update` にキーごと渡して丸ごと差し替えられるのに対し、こちらはリストなので
---同じことをすると他の要素が全部消える。該当する1要素だけを差し替える。
local OrchestrationChatScanner = {}
OrchestrationChatScanner.__index = OrchestrationChatScanner

local Scanner = require("vibing.infrastructure.link.scanner")
local Frontmatter = require("vibing.infrastructure.storage.frontmatter")
local FrontmatterFile = require("vibing.infrastructure.storage.frontmatter_file")
local Git = require("vibing.core.utils.git")
local OrchestratedEntry = require("vibing.application.chat.orchestrated_entry")

setmetatable(OrchestrationChatScanner, { __index = Scanner })

---両方向を1本のスキャナーで見る。リネームされたのが A でも B でも、相手側のファイルは
---この2キーのどちらかに old_path を持っているので、スキャナーを分ける理由がない。
---分ければ全ファイルの読み込みと `git rev-parse` が二重になるだけになる
local LINK_KEYS = { "orchestrated", "orchestrated_by" }

---`orchestrated`だけ要素が`<path>`または`<path>|<task>`(#696)。`orchestrated_by`は
---今まで通りpathそのものなので、このモジュールが両キーを同じループで扱うために
---「要素からpath部分を取り出す/差し替える」をキーごとに切り替える
---@param key string
---@param item string
---@return string path
local function item_path(key, item)
  if key == "orchestrated" then
    return (OrchestratedEntry.decode(item))
  end
  return item
end

---@param key string
---@param item string 元の要素（taskの有無を保つため必要）
---@param new_path string
---@return string
local function item_with_path(key, item, new_path)
  if key == "orchestrated" then
    local _, task = OrchestratedEntry.decode(item)
    return OrchestratedEntry.encode(new_path, task)
  end
  return new_path
end

---@return Vibing.Infrastructure.Link.OrchestrationChatScanner
function OrchestrationChatScanner.new()
  return setmetatable({}, OrchestrationChatScanner)
end

---frontmatter に書かれた表示パスを絶対パスに正規化する
---@param value string
---@return string
function OrchestrationChatScanner:_to_absolute(value)
  return Git.from_display_path(value, self:git_root())
end

---チャットファイルの frontmatter を読む
---
---チャット保存ディレクトリには手書きのメモが置かれていることがある。リンクキーの有無だけで
---判定すると、たまたま同名のキーを持つ `.md` を書き換えてしまう
---@param file_path string
---@return table?
function OrchestrationChatScanner:_read_chat(file_path)
  local frontmatter = self:read_frontmatter(file_path)
  if not frontmatter or frontmatter["vibing.nvim"] ~= true then
    return nil
  end
  return frontmatter
end

---@param file_path string
---@param target_path string
---@return boolean
function OrchestrationChatScanner:contains_link(file_path, target_path)
  local frontmatter = self:_read_chat(file_path)
  if not frontmatter then
    return false
  end

  local target_abs = vim.fn.fnamemodify(target_path, ":p")

  for _, key in ipairs(LINK_KEYS) do
    for _, item in ipairs(Frontmatter.as_list(frontmatter[key])) do
      if self:_to_absolute(item_path(key, item)) == target_abs then
        return true
      end
    end
  end

  return false
end

---@param file_path string
---@param old_path string
---@param new_path string
---@return boolean success
---@return string? error
function OrchestrationChatScanner:update_link(file_path, old_path, new_path)
  local frontmatter = self:_read_chat(file_path)
  if not frontmatter then
    return false, "Not a vibing chat file"
  end

  local old_abs = vim.fn.fnamemodify(old_path, ":p")
  local new_display = Git.to_display_path(new_path)

  local updates = {}
  for _, key in ipairs(LINK_KEYS) do
    local replaced = false
    local seen = {}
    local next_items = {}

    for _, item in ipairs(Frontmatter.as_list(frontmatter[key])) do
      local value = item
      if self:_to_absolute(item_path(key, item)) == old_abs then
        value = item_with_path(key, item, new_display)
        replaced = true
      end
      -- 差し替え先が既にリストに載っていれば重複になる。リネーム先の衝突は
      -- `set_file_title` が避けるが、このメソッド自体は任意の new_path で呼べる
      if not seen[value] then
        seen[value] = true
        table.insert(next_items, value)
      end
    end

    if replaced then
      updates[key] = next_items
    end
  end

  if not next(updates) then
    return false, "No orchestration link to update"
  end

  -- ディスクに直接書かない。オーケストレーションのリンクはbufnr起点で張られるので、相手側の
  -- チャットはほぼ必ず開いている（FrontmatterFile のコメント参照）
  return FrontmatterFile.update(file_path, updates)
end

return OrchestrationChatScanner
