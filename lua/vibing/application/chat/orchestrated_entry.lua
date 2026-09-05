---@class Vibing.Application.Chat.OrchestratedEntry
---`orchestrated` フロントマターの1要素（`<path>` または `<path>|<task>`）の符号化/復号（#696）。
---
---`orchestrated_by` はpathだけのフラットな文字列リストのままなので、この符号化は
---`orchestrated`側にしか登場しない。taskはそれを頼んだ側（親）の`orchestrated`エントリに
---しか持たせない設計で、子の frontmatter には複製しない — 正本を1箇所にすることで、
---「最新の指示に置き換える」更新（`orchestration_link.link`）が親側1ファイルの書き換えで
---閉じ、子側との同期漏れが構造上起きえなくなる。
---
---区切りに `|` を使うのは、チャットファイルのpathには絶対に出てこない文字であることに加えて、
---Vimの既定`isfname`に含まれないため — `-`や`#`はisfnameに含まれるが`|`は含まれないので、
---`orchestrated`の行でカーソルがpath部分にある限り`gf`は`|`の手前で必ず止まり、task側の文字列
---（`#688`のような`#`を含む語）まで読み進めない（実機で確認済み）。
local M = {}

local SEP = "|"

---@param path string
---@param task string? 空文字/nilならtask無しのエントリを返す
---@return string
function M.encode(path, task)
  if task and task ~= "" then
    return path .. SEP .. task
  end
  return path
end

---@param entry string
---@return string path
---@return string? task 区切りが無ければnil
function M.decode(entry)
  local sep = entry:find(SEP, 1, true)
  if not sep then
    return entry, nil
  end
  return entry:sub(1, sep - 1), entry:sub(sep + 1)
end

---`entries` の中から `path` に一致する要素を探す
---@param entries string[]
---@param path string
---@return string? entry 見つかった生の要素（符号化されたまま）
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

return M
