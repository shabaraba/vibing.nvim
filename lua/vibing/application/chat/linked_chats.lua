---@class Vibing.Application.Chat.LinkedChats
---frontmatter のリンクで繋がったチャットの連結成分を返す。
---
---`orchestration_tree` が「オーケストレーションの木」を向きごと描くのに対し、こちらは向きを
---落とした**網**を返す。`:VibingSetFileTitle --linked` のように「関係している会話をまとめて
---処理する」側が知りたいのは親子の別ではなく範囲なので、辺の向きは持たない。
---
---向きを落とすのは表示上の都合ではなく、リンクの記録のされ方からの要請になる。
---`forked_from` / `continued_from` / `orchestrated_by` は**子から親への一方向にしか書かれない**
---（fork 元は自分が fork されたことを知らない）。自分の frontmatter だけを読む実装は、
---そこから派生したチャットを永久に見つけられない。なので起点のあるディレクトリを1回走査して、
---自分を指しているチャットも辺として拾う。
---
---このモジュールが持つのはグラフの組み立てだけで、その下は既にあるものを使う:
---チャットファイルの集合は `Scanner`、パス解決とバッファ対応は `ChatLocator`、
---frontmatter の読み出しは `Frontmatter.read`、フィールドの定義は `ChatLinks.FIELDS`。
local M = {}

local ChatLinks = require("vibing.core.constants.chat_links")
local ChatLocator = require("vibing.application.chat.chat_locator")
local Frontmatter = require("vibing.infrastructure.storage.frontmatter")
local OrchestratedEntry = require("vibing.application.chat.orchestrated_entry")
local PathSanitizer = require("vibing.domain.security.path_sanitizer")
local Scanner = require("vibing.infrastructure.link.scanner")

---frontmatter が名指しているチャットの実体パスを集める
---@param data table
---@return string[]
local function outbound(data)
  local abs_paths = {}
  for _, field in ipairs(ChatLinks.FIELDS) do
    for _, path in ipairs(OrchestratedEntry.field_paths(data, field.key)) do
      local abs = ChatLocator.resolve_abs(path)
      if abs then
        table.insert(abs_paths, abs)
      end
    end
  end
  return abs_paths
end

---指定ディレクトリを1回走査して、辺を両向きぶん組み立てる
---@param base_dir string
---@return table<string, string[]> outbound_by_abs 走査できたファイルが名指している先
---@return table<string, string[]> inbound_by_abs そのパスを名指しているファイル
local function scan(base_dir)
  local outbound_by_abs = {}
  local inbound_by_abs = {}

  if base_dir:sub(-1) ~= "/" then
    base_dir = base_dir .. "/"
  end
  -- 「どの拡張子がチャットファイルか」の定義は `Scanner` にある。`find_target_files` は
  -- selfを見ないので、スキャナーを1つ作らずにそのまま呼べる
  local files = Scanner.find_target_files(Scanner, base_dir)

  -- bufnr の解決は1回にまとめる。`resolve_all` は呼び出しごとに全バッファを走査するので、
  -- ファイルごとに呼ぶと保存ディレクトリのファイル数だけ走査が走る
  for _, entry in ipairs(ChatLocator.resolve_all(files)) do
    local targets = outbound(Frontmatter.read(entry.abs, entry.bufnr) or {})
    outbound_by_abs[entry.abs] = targets

    for _, target in ipairs(targets) do
      inbound_by_abs[target] = inbound_by_abs[target] or {}
      table.insert(inbound_by_abs[target], entry.abs)
    end
  end

  return outbound_by_abs, inbound_by_abs
end

---起点のチャットとリンクで繋がったチャットを、起点を除いて返す
---
---辿るのは幅優先で、返す並びはそうしてできた**張り木の先行順**。この2つを分けているのは、
---辿る順と見せる順で要るものが違うから。幅優先は起点からの距離が最短になる親を選ぶので、
---「どこから繋がっているか」が一番近い関係で決まる。一方、並びのほうは木として描けないと困る
---（`depth` だけで罫線を組むには、子が親のすぐ下に来ている必要がある）。処理はこの並びで進むので、
---表示された木は上から順に埋まっていく。
---
---リンクは手で書ける frontmatter なので循環しうるが、`seen` で止まる。実体の無いパス
---（消されたチャット）は辺としては辿り、結果には入れない — 開いていないだけのチャットと
---区別できるのはファイルの有無だけになる。飛ばしたノードの子は、その深さを引き継いで繰り上がる
---@param origin_path string? 起点チャットのファイルパス（未保存なら nil）
---@param origin_bufnr number? 起点チャットのバッファ番号
---@return {path: string, abs: string, bufnr: number?, depth: integer}[] 起点を深さ0としたときの深さ付き
function M.collect(origin_path, origin_bufnr)
  local origin_abs = origin_path and PathSanitizer.normalize(origin_path)
  if not origin_abs then
    return {}
  end

  -- 走査するのは起点が実際に置かれているディレクトリ。設定の保存先で決め打つと、別プロジェクトの
  -- チャットを開いている場合（`set_file_title.lua` の `target_dir` と同じ理由）に、そのディレクトリ
  -- 内で起点を指している兄弟チャットを永遠に見つけられない
  local origin_dir = vim.fn.fnamemodify(origin_abs, ":h") .. "/"
  local outbound_by_abs, inbound_by_abs = scan(origin_dir)
  -- 走査結果はキャッシュなので、開いているバッファを優先させるために読み直す
  outbound_by_abs[origin_abs] = outbound(Frontmatter.read(origin_abs, origin_bufnr) or {})

  local seen = { [origin_abs] = true }
  local queue = { origin_abs }
  ---@type table<string, string[]> 張り木の枝。最初にそのノードへ到達した親にぶら下がる
  local children = {}

  while #queue > 0 do
    local current = table.remove(queue, 1)

    -- 走査の外から辿り着いたノードはここで読む。起点のディレクトリの外にあるノードなら、その先も外にある。
    -- `neighbours` は必ず新しいテーブルにする — `list_extend` は第1引数を書き換えるので、
    -- `outbound_by_abs[current]` をそのまま渡すと走査結果に inbound 側が混ざる
    local neighbours = {}
    vim.list_extend(neighbours, outbound_by_abs[current] or outbound(Frontmatter.read(current, nil) or {}))
    vim.list_extend(neighbours, inbound_by_abs[current] or {})

    for _, neighbour in ipairs(neighbours) do
      if not seen[neighbour] then
        seen[neighbour] = true
        table.insert(queue, neighbour)
        children[current] = children[current] or {}
        table.insert(children[current], neighbour)
      end
    end
  end

  local found, depth_by_abs = {}, {}
  local function walk(abs, depth)
    for _, child in ipairs(children[abs] or {}) do
      local readable = vim.fn.filereadable(child) == 1
      if readable then
        table.insert(found, child)
        depth_by_abs[child] = depth
      end
      walk(child, readable and depth + 1 or depth)
    end
  end
  walk(origin_abs, 1)

  -- 実体パスで引く。添字を揃える書き方だと `resolve_all` が1件も落とさないことに頼ることになり、
  -- あれは空文字列や文字列でない要素を落とす
  local entries = ChatLocator.resolve_all(found)
  for _, entry in ipairs(entries) do
    entry.depth = depth_by_abs[entry.abs]
  end
  return entries
end

return M
