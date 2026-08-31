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

setmetatable(OrchestrationChatScanner, { __index = Scanner })

---両方向を1本のスキャナーで見る。リネームされたのが A でも B でも、相手側のファイルは
---この2キーのどちらかに old_path を持っているので、スキャナーを分ける理由がない。
---分ければ全ファイルの読み込みと `git rev-parse` が二重になるだけになる
local LINK_KEYS = { "orchestrated", "orchestrated_by" }

---@return Vibing.Infrastructure.Link.OrchestrationChatScanner
function OrchestrationChatScanner.new()
  return setmetatable({}, OrchestrationChatScanner)
end

---`Git.get_root()` は毎回 `git rev-parse` を起動する。1ファイルにつきリンク要素の数だけ
---呼ぶことになるので、スキャナーインスタンスの生存期間（＝1回の同期）だけキャッシュする。
---見つからなかったことも `false` として覚え、毎回引き直さない
---@return string?
function OrchestrationChatScanner:_git_root()
  if self._git_root_cache == nil then
    self._git_root_cache = Git.get_root() or false
  end
  return self._git_root_cache or nil
end

---frontmatter に書かれた表示パスを絶対パスに正規化する
---@param value string
---@return string
function OrchestrationChatScanner:_to_absolute(value)
  local git_root = self:_git_root()
  if git_root and not value:match("^[/~]") then
    return vim.fs.joinpath(git_root, value)
  end
  return vim.fn.fnamemodify(vim.fn.expand(value), ":p")
end

---リンクフィールドを配列として読む。
---
---2つの落とし穴を吸収する。空リストは `{}` という**真値の table** としてパースされるので
---`if not value` では弾けない。そして手で `orchestrated: path.md` と1行で書かれていれば
---table ではなく**文字列**として返ってくる
---@param frontmatter table
---@param key string
---@return string[]
local function read_link_list(frontmatter, key)
  local value = frontmatter[key]
  if type(value) == "string" and value ~= "" then
    return { value }
  end
  if type(value) ~= "table" then
    return {}
  end
  return value
end

---@param file_path string
---@return table?
local function read_frontmatter(file_path)
  local ok, content = pcall(vim.fn.readfile, file_path)
  if not ok or not content or #content == 0 then
    return nil
  end

  local frontmatter = Frontmatter.parse(table.concat(content, "\n"))
  -- チャット保存ディレクトリには手書きのメモが置かれていることがある。リンクキーの
  -- 有無だけで判定すると、たまたま同名のキーを持つ `.md` を書き換えてしまう
  if not frontmatter or frontmatter["vibing.nvim"] ~= true then
    return nil
  end
  return frontmatter
end

---@param base_dir string
---@return string[]
function OrchestrationChatScanner:find_target_files(base_dir)
  if vim.fn.isdirectory(base_dir) == 0 then
    return {}
  end

  local md_files = vim.fn.glob(base_dir .. "**/*.md", false, true)
  local vibing_files = vim.fn.glob(base_dir .. "**/*.vibing", false, true)

  return vim.list_extend(md_files, vibing_files)
end

---@param file_path string
---@param target_path string
---@return boolean
function OrchestrationChatScanner:contains_link(file_path, target_path)
  local frontmatter = read_frontmatter(file_path)
  if not frontmatter then
    return false
  end

  local target_abs = vim.fn.fnamemodify(target_path, ":p")

  for _, key in ipairs(LINK_KEYS) do
    for _, item in ipairs(read_link_list(frontmatter, key)) do
      if self:_to_absolute(item) == target_abs then
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
  local ok, lines = pcall(vim.fn.readfile, file_path)
  if not ok or not lines then
    return false, string.format("Failed to read file: %s", lines or "unknown")
  end

  local text = table.concat(lines, "\n")
  local frontmatter = Frontmatter.parse(text)
  if not frontmatter then
    return false, "No frontmatter"
  end

  local old_abs = vim.fn.fnamemodify(old_path, ":p")
  local new_display = Git.to_display_path(new_path)

  local updates = {}
  for _, key in ipairs(LINK_KEYS) do
    local replaced = false
    local seen = {}
    local next_items = {}

    for _, item in ipairs(read_link_list(frontmatter, key)) do
      local value = item
      if self:_to_absolute(item) == old_abs then
        value = new_display
        replaced = true
      end
      -- リネーム先が既にリストに載っていることがある（A が B と C の両方を指していて、
      -- B が C の名前に改名された場合）。差し替えたあとに重複を落とす
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
