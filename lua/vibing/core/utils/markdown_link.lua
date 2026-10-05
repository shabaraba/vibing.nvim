---@class Vibing.Utils.MarkdownLink
---Markdown のインラインリンク `[label](dest)` を、行とカーソル位置から取り出す。
---
---`gx` / `gf` / `gd` が「記法のどこにカーソルがあっても飛ぶ」ために共有する唯一の判定。
---ラベル上では `<cfile>` がラベルの文字列を拾ってしまうので、記法そのものを読む必要がある。
local M = {}

---`(...)` の中身からリンク先だけを取り出す。
---`<...>` 囲みを外し、空白に続くタイトル（`"..."` / `'...'`）を落とす。
---CommonMark では `<>` で囲まない限りリンク先に空白を書けないので、最初の空白までで足りる。
---@param inner string `(` `)` を除いた中身
---@return string
local function destination_of(inner)
  local dest = vim.trim(inner)
  -- `<...>` の後ろにタイトルが続くことがあるので、終端ではなく最初の `>` で切る
  local angled = dest:match("^<([^>]*)>")
  if angled then
    return angled
  end
  return dest:match("^(%S*)") or ""
end

---行内からカーソル位置を含むインラインリンクを探し、そのリンク先を返す。
---`![alt](path)` の `!` も記法の一部として扱う。
---@param line string 行全体
---@param col number カーソルの 1-indexed バイトカラム
---@return string? リンク先（記法の外なら nil）
function M.find_at(line, col)
  local search = 1
  while true do
    local open = line:find("[", search, true)
    if not open then
      return nil
    end

    -- `%b[]` はネストした角括弧にも対応する。リンク先は `]` の直後に続く場合だけ有効
    local label = line:match("^%b[]", open)
    local inner = label and line:match("^%b()", open + #label)

    if inner then
      local start_col = (open > 1 and line:sub(open - 1, open - 1) == "!") and open - 1 or open
      if start_col > col then
        -- `find` は左から進むので、これより後ろのリンクもカーソルを含まない
        return nil
      end
      if col <= open + #label + #inner - 1 then
        local dest = destination_of(inner:sub(2, -2))
        return dest ~= "" and dest or nil
      end
    end
    search = open + 1
  end
end

---リンク先が何を指しているかを分類する。`gx` は URL を、`gf` / `gd` は path を取る。
---スキームの綴りを各キーマップが書き分けると、どちらも取らない隙間ができる
---@param dest string
---@return "url"|"anchor"|"path"
function M.classify(dest)
  if dest:match("^%a[%w+.%-]*://") or dest:match("^mailto:") then
    return "url"
  end
  if dest:sub(1, 1) == "#" then
    return "anchor"
  end
  return "path"
end

return M
