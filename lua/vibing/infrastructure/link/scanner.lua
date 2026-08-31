---@class Vibing.Infrastructure.Link.Scanner
---リンク同期スキャナーの基底。
---
---走査そのもの（どのファイルを見るか、それを読む・gitルートを引く）は全スキャナーで同じなので
---ここに集約し、サブクラスはリンクの解釈だけを持つ。キャッシュはインスタンス単位＝1回の同期の
---生存期間で、`SyncManager` が毎回 `new()` するのでスキャン間に持ち越さない。
local Scanner = {}
Scanner.__index = Scanner

local Frontmatter = require("vibing.infrastructure.storage.frontmatter")

---走査対象のチャットファイルを集める
---
---「どの拡張子がチャットファイルか」は個々のスキャナーの関心ではないので、ここが唯一の定義。
---別の集め方をするスキャナー（daily summaryなど）だけが上書きする
---@param base_dir string 末尾に "/" が必要（そのまま連結する）
---@return string[]
function Scanner:find_target_files(base_dir)
  if vim.fn.isdirectory(base_dir) == 0 then
    return {}
  end

  -- チャットバッファは .md、保存形式としては .vibing もありうる
  local md_files = vim.fn.glob(base_dir .. "**/*.md", false, true)
  local vibing_files = vim.fn.glob(base_dir .. "**/*.vibing", false, true)

  return vim.list_extend(md_files, vibing_files)
end

---ファイルのfrontmatterを読む
---
---`SyncManager` は同じファイルに対して `contains_link` の直後に `update_link` を呼ぶので、
---キャッシュしないとチャットの全文を続けて2回読むことになる。チャットのtranscriptは
---このリポジトリで最も大きいファイル群なので、これは実測できる差になる
---@param file_path string
---@return table?
function Scanner:read_frontmatter(file_path)
  self._frontmatter_cache = self._frontmatter_cache or {}

  local cached = self._frontmatter_cache[file_path]
  if cached ~= nil then
    return cached or nil
  end

  local ok, content = pcall(vim.fn.readfile, file_path)
  if not ok or not content or #content == 0 then
    self._frontmatter_cache[file_path] = false
    return nil
  end

  local frontmatter = Frontmatter.parse(table.concat(content, "\n"))
  self._frontmatter_cache[file_path] = frontmatter or false
  return frontmatter
end

---gitルートを引く
---
---`Git.get_root()` はキャッシュを持たず毎回 `git rev-parse` を起動する。走査は1ファイルにつき
---リンク要素の数だけ正規化を行うので、キャッシュしないと数百のサブプロセスが同期的に走る。
---不在は `false` のまま返す（`nil` に潰すと `Git.from_display_path` が「未指定」と読んで引き直す）
---@return string|false
function Scanner:git_root()
  if self._git_root_cache == nil then
    self._git_root_cache = require("vibing.core.utils.git").get_root() or false
  end
  return self._git_root_cache
end

---@param file_path string
---@param target_path string
---@return boolean
function Scanner:contains_link(file_path, target_path)
  error("Must be implemented by subclass")
end

---@param file_path string
---@param old_path string
---@param new_path string
---@return boolean success
---@return string? error
function Scanner:update_link(file_path, old_path, new_path)
  error("Must be implemented by subclass")
end

return Scanner
