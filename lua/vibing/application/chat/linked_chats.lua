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
---そこから派生したチャットを永久に見つけられない。なので保存ディレクトリを1回走査して、
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

---保存ディレクトリを1回走査して、辺を両向きぶん組み立てる
---@param save_dir string
---@return table<string, string[]> outbound_by_abs 走査できたファイルが名指している先
---@return table<string, string[]> inbound_by_abs そのパスを名指しているファイル
local function scan(save_dir)
  local outbound_by_abs = {}
  local inbound_by_abs = {}

  if save_dir:sub(-1) ~= "/" then
    save_dir = save_dir .. "/"
  end
  -- 「どの拡張子がチャットファイルか」の定義は `Scanner` にある。`find_target_files` は
  -- selfを見ないので、スキャナーを1つ作らずにそのまま呼べる
  local files = Scanner.find_target_files(Scanner, save_dir)

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
---幅優先で辿るので、並びは起点に近いものから。リンクは手で書ける frontmatter なので循環
---しうるが、`seen` で止まる。実体の無いパス（消されたチャット）は辺としては辿り、結果には
---入れない — 開いていないだけのチャットと区別できるのはファイルの有無だけになる
---@param origin_path string? 起点チャットのファイルパス（未保存なら nil）
---@param origin_bufnr number? 起点チャットのバッファ番号
---@return {path: string, abs: string, bufnr: number?}[]
function M.collect(origin_path, origin_bufnr)
  local origin_abs = origin_path and PathSanitizer.normalize(origin_path)
  if not origin_abs then
    return {}
  end

  local FileManager = require("vibing.presentation.chat.modules.file_manager")
  local outbound_by_abs, inbound_by_abs = scan(FileManager.get_save_directory(require("vibing").get_config().chat))
  -- 起点は保存ディレクトリの外にありうる（別プロジェクトのチャットを開いている場合）ので、
  -- 走査に頼らず読み直す。開いているバッファを優先させる意味もある
  outbound_by_abs[origin_abs] = outbound(Frontmatter.read(origin_abs, origin_bufnr) or {})

  local seen = { [origin_abs] = true }
  local queue = { origin_abs }
  local found = {}

  while #queue > 0 do
    local current = table.remove(queue, 1)

    -- 走査の外から辿り着いたノードはここで読む。起点が保存ディレクトリの外なら、その先も外にある。
    -- `neighbours` は必ず新しいテーブルにする — `list_extend` は第1引数を書き換えるので、
    -- `outbound_by_abs[current]` をそのまま渡すと走査結果に inbound 側が混ざる
    local neighbours = {}
    vim.list_extend(neighbours, outbound_by_abs[current] or outbound(Frontmatter.read(current, nil) or {}))
    vim.list_extend(neighbours, inbound_by_abs[current] or {})

    for _, neighbour in ipairs(neighbours) do
      if not seen[neighbour] then
        seen[neighbour] = true
        table.insert(queue, neighbour)
        if vim.fn.filereadable(neighbour) == 1 then
          table.insert(found, neighbour)
        end
      end
    end
  end

  return ChatLocator.resolve_all(found)
end

return M
