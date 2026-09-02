---@class Vibing.Application.OrchestrationTree
---`orchestrated` / `orchestrated_by` の frontmatter から、チャット網を木として読み出す。
---
---関係の記録は既に永続層（パスのリスト）にあり、`OrchestrationChatScanner` が改名にも
---追従させている。足りなかったのは**それを一望する手段**だけで、オーケストレータの
---トランスクリプトを読んでも分かるのは自分が配ったところまで — 孫は出てこない。
---
---読む先を「開いていればバッファ、そうでなければファイル」の順にするのがこのモジュールの
---肝になる。木のノードの大半は `back` で作られた窓なしのワーカーで、`:VibingChat` の性質上
---1ターン目までディスクに書かれないものもある。どちらか一方しか読まないと、木は黙って
---途中で切れる。
local M = {}

local ChatLocator = require("vibing.application.chat.chat_locator")
local Frontmatter = require("vibing.infrastructure.storage.frontmatter")

---親を遡るときの上限。`orchestrated_by` は手で書ける frontmatter なので、循環していなくても
---異常に深い鎖はありうる。`seen` で循環は止まるが、深さの歯止めはこれとは別に要る
local MAX_ASCENT = 64

---@class Vibing.Application.OrchestrationTree.Node
---@field path string gitルート相対の表示パス
---@field abs string 実体パス
---@field bufnr number? 開いていなければ nil
---@field children Vibing.Application.OrchestrationTree.Node[]
---@field repeated boolean 木の上位に既に現れたノード。子は辿らない

---ノード1つぶんの frontmatter を読む
---
---バッファを優先するのは、保存前の編集も含めて「いまの関係」を答えるため。オーケストレータは
---配布のたびに `orchestrated` を書き足すので、保存が追いつく前に木を見ると新しい子が消える
---@param entry {path: string, abs: string, bufnr: number?}
---@return table
local function frontmatter_of(entry)
  local region
  if entry.bufnr and vim.api.nvim_buf_is_valid(entry.bufnr) and vim.api.nvim_buf_is_loaded(entry.bufnr) then
    region = Frontmatter.buffer_region(entry.bufnr)
  end
  region = region or Frontmatter.file_region(entry.abs)
  if not region then
    return {}
  end

  return (Frontmatter.parse(table.concat(region, "\n"))) or {}
end

---@param entry {path: string, abs: string, bufnr: number?}
---@param key "orchestrated"|"orchestrated_by"
---@return {path: string, abs: string, bufnr: number?}[]
local function linked(entry, key)
  return ChatLocator.resolve_all(frontmatter_of(entry)[key])
end

---@param display_path string
---@return {path: string, abs: string, bufnr: number?}?
local function entry_for(display_path)
  return ChatLocator.resolve_all({ display_path })[1]
end

---表示パスを根として、`orchestrated` を辿った木を組む
---
---同じチャットが2度現れたら `repeated` を立ててそこで止める。frontmatter は手で書けるので
---循環しうるし、1つのワーカーが2人のオーケストレータから使われている形も表現できてしまう。
---どちらも落とさずに描いて、辿り直しだけをやめる
---@param display_path string
---@return Vibing.Application.OrchestrationTree.Node?
function M.build(display_path)
  local root = entry_for(display_path)
  -- 根だけは実在を確かめる。打ち間違えたパスも表示パスとしては解決できてしまうので、
  -- 確かめないと「そのチャットは誰も動かしていない」という体裁の1ノードの木が返る。
  -- 子には同じ検査をしない — frontmatter がまだ名前を挙げている以上、消えた子は
  -- 「開いていない」として描かれるほうが情報になる
  if not root or not (root.bufnr or vim.fn.filereadable(root.abs) == 1) then
    return nil
  end

  local seen = {}

  local function node_for(entry)
    if seen[entry.abs] then
      return { path = entry.path, abs = entry.abs, bufnr = entry.bufnr, children = {}, repeated = true }
    end
    seen[entry.abs] = true

    local node = { path = entry.path, abs = entry.abs, bufnr = entry.bufnr, children = {}, repeated = false }
    for _, child in ipairs(linked(entry, "orchestrated")) do
      table.insert(node.children, node_for(child))
    end
    return node
  end

  return node_for(root)
end

---`orchestrated_by` を遡って、この表示パスが属する木の根を返す
---
---親が複数記録されていたら先頭を採る。木として運用する前提なので分岐はしないはずだが、
---手書きの frontmatter は何でも書けるので、選ばずに諦めるよりは1本に決めて描くほうがよい
---@param display_path string
---@return string root_path 遡れなければ渡されたパスがそのまま返る
function M.root_of(display_path)
  local seen = {}
  local current = display_path

  for _ = 1, MAX_ASCENT do
    local entry = entry_for(current)
    if not entry or seen[entry.abs] then
      return current
    end
    seen[entry.abs] = true

    local parent = linked(entry, "orchestrated_by")[1]
    if not parent then
      return current
    end
    current = parent.path
  end

  return current
end

---木を行きがけ順に平らにする
---@param node Vibing.Application.OrchestrationTree.Node?
---@return Vibing.Application.OrchestrationTree.Node[]
function M.flatten(node)
  local nodes = {}
  local function walk(current)
    table.insert(nodes, current)
    for _, child in ipairs(current.children) do
      walk(child)
    end
  end
  if node then
    walk(node)
  end
  return nodes
end

---表示パスを実体パスに揃える。木のどのノードが「いまいる場所」かを照合するために使う
---@param display_path string
---@return string?
function M.abs_of(display_path)
  local entry = entry_for(display_path)
  return entry and entry.abs
end

---バッファをこのモジュールが扱う表示パスに変換する
---@param bufnr number
---@return string? display_path 名前のないバッファなら nil
function M.display_path_of(bufnr)
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == "" then
    return nil
  end
  return require("vibing.core.utils.git").to_display_path(name)
end

return M
