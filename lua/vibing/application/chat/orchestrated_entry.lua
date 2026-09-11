---@class Vibing.Application.Chat.OrchestratedEntry
---`orchestrated` フロントマターの1要素の符号化/復号（#696、#717）。
---
---taskの無い要素はpathそのもの、taskを持つ要素は `{ path, task }` のマップになる:
---
---```yaml
---orchestrated:
---  - .vibing/chat/idle.md
---  - path: .vibing/chat/worker.md
---    task: "PR #688 -- review fixes, merge"
---```
---
---`orchestrated_by` はpathだけのフラットな文字列リストのままなので、マップ要素は
---`orchestrated`側にしか現れない。taskはそれを頼んだ側（親）の`orchestrated`エントリに
---しか持たせない設計で、子の frontmatter には複製しない — 正本を1箇所にすることで、
---「最新の指示に置き換える」更新（`orchestration_link.link`）が親側1ファイルの書き換えで
---閉じ、子側との同期漏れが構造上起きえなくなる。
---
---taskをpathと同じ行に持たない形なので、`orchestrated`の行にカーソルを置いた `gf` は
---path以外を読まない。#712 が `|` 区切りを選んだ理由（Vimの既定`isfname`に`|`が
---含まれない）は、入れ子で書けるようになった時点で構造そのものが引き受けている。
local M = {}

---#712 が使っていた `<path>|<task>` の区切り。既存のチャットファイルを読むためだけに残す。
---`M.encode` は二度とこの形を書かない
local LEGACY_SEP = "|"

---@alias Vibing.OrchestratedEntry string|{path: string, task: string?}

---@param path string
---@param task string? 空文字/nilならtask無しのエントリを返す
---@return Vibing.OrchestratedEntry
function M.encode(path, task)
  if task and task ~= "" then
    return { path = path, task = task }
  end
  return path
end

---@param entry Vibing.OrchestratedEntry 手書きされうるので任意の値を受ける
---@return string? path 読めない要素ならnil
---@return string? task 無ければnil
function M.decode(entry)
  if type(entry) == "table" then
    local path, task = entry.path, entry.task
    if type(path) ~= "string" or path == "" then
      return nil, nil
    end
    return path, (type(task) == "string" and task ~= "") and task or nil
  end

  if type(entry) ~= "string" or entry == "" then
    return nil, nil
  end

  local sep = entry:find(LEGACY_SEP, 1, true)
  if not sep then
    return entry, nil
  end
  return entry:sub(1, sep - 1), entry:sub(sep + 1)
end

---`entries` の中から `path` に一致する要素を探す
---@param entries Vibing.OrchestratedEntry[]
---@param path string
---@return Vibing.OrchestratedEntry? entry 見つかった要素（符号化されたまま。`remove`にそのまま渡せる）
---@return string? task
function M.find(entries, path)
  for _, entry in ipairs(entries) do
    local entry_path, task = M.decode(entry)
    if entry_path == path then
      return entry, task
    end
  end
  return nil, nil
end

---`entries` の各要素からpathだけを取り出す（読めない要素は落とす）
---@param entries Vibing.OrchestratedEntry[]
---@return string[]
function M.paths(entries)
  local paths = {}
  for _, entry in ipairs(entries) do
    local path = M.decode(entry)
    if path then
      table.insert(paths, path)
    end
  end
  return paths
end

return M
