---@class Vibing.Application.Chat.ChatLocator
---チャットファイルのパスを、いま生きているバッファ番号に解決する。
---
---bufnr は Neovim を再起動すれば別のバッファを指すが、frontmatter が記録するパスは残る。
---MCP ツールが bufnr しか受け取らないと、永続層（パス）は正しいのに揮発層（bufnr）だけで
---会話することになり、再起動を跨いだオーケストレーション網は二度と繋がらない（#641）。
---
---ここが「パス → bufnr」の変換点。開かれていないチャットは `open` が背景で開くので、
---「相手が閉じているから届かない」は答えにならない。復旧の手順は「人間が任意のノードを蹴る」で、
---蹴られたノードは frontmatter のパスから相手を引き直す。
local M = {}

local Git = require("vibing.core.utils.git")
local PathSanitizer = require("vibing.domain.security.path_sanitizer")

---`Git.get_root()` はキャッシュを持たず、毎回 `vim.system():wait()` で同期的に
---`git rev-parse` を起動する。`resolve_all` はワーカーチャットの**送信のたび**に呼ばれるので、
---そのままではユーザーの `<CR>` の前でメインスレッドがプロセス起動1回分ブロックする。
---値はcwdごとに固定なので、cwdをキーに覚える
---@type table<string, string>
local git_root_by_cwd = {}

---**成功だけを覚える。** 「gitリポジトリではない」を覚えると、あとから `git init` された
---（あるいはworktreeが生えた）ディレクトリが、そのNeovimが生きている限り誤判定のままになる。
---外したときのコストは fail-fast な `rev-parse` 1回だけ。
---`core/utils/git_snapshot.lua` の `root_cache` と同じ方針で、handbook/architecture/per-request-diffs.md にも明文化がある。
---
---3値を保つのは `Git.from_display_path` の契約に合わせるため。`false`（リポジトリ外だと
---分かっている）を `nil`（未指定＝引き直せ）に潰すと、リポジトリ外ではキャッシュが一切効かず、
---パス1件ごとに `git rev-parse` が起動する
---@return string|false
local function cached_git_root()
  local cwd = vim.fn.getcwd()
  if git_root_by_cwd[cwd] then
    return git_root_by_cwd[cwd]
  end

  local root = Git.get_root()
  if root then
    git_root_by_cwd[cwd] = root
  end
  return root or false
end

---表示パス（gitルート相対 / 絶対 / `~`）を、比較に使える実体パスへ揃える
---@param display_path string 空でないことは呼び出し元が確かめる
---@param git_root string|false
---@return string abs
local function to_abs(display_path, git_root)
  return PathSanitizer.normalize(Git.from_display_path(vim.trim(display_path), git_root))
end

---いま開いているバッファを、実体パスから引ける形にする
---
---比較は両側ともシンボリックリンクを解決した形で行う。`nvim_buf_get_name` は解決済みの
---パスを返すので（macOSでは `/var/...` が `/private/var/...` になる）、`:p` だけでは
---同じファイルが一致しない。
---
---走査は呼び出しごとに1回で、探すパスの件数には依存しない。件数で回すと、送信のたびに
---`orchestrated_by` の要素数ぶんの全バッファ走査になる
---@return table<string, number>
local function buffers_by_abs()
  local map = {}
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      local name = vim.api.nvim_buf_get_name(bufnr)
      if name ~= "" then
        local abs = PathSanitizer.normalize(name)
        -- `nvim_list_bufs` は昇順なので、同じファイルに複数バッファが付いていたら
        -- いちばん古いものが残る
        map[abs] = map[abs] or bufnr
      end
    end
  end
  return map
end

---表示パスの並びを、いま開いているバッファ番号と対にして返す
---
---開かれていないチャットは番号を持たないので `bufnr` が `nil` のまま返る — **落とさない**のが
---以前の `resolve_bufnrs` との違いで、パスだけでも相手を名指しできるのが #641 の要点
---
---`abs` も返す。開いていないチャットのfrontmatterを読む側（`orchestration_tree`）が必要とし、
---ここは既に git ルートのキャッシュを持っているので、呼び出し元に解決をやり直させると
---同じ変換が2回走る
---@param display_paths string[]|string|nil
---@return {path: string, abs: string, bufnr: number?}[]
function M.resolve_all(display_paths)
  -- 手で `orchestrated_by: path.md` と1行で書かれると文字列としてパースされる形も含めて、
  -- リストフィールドの3つの形は `Frontmatter.as_list` が吸収する
  local paths = require("vibing.infrastructure.storage.frontmatter").as_list(display_paths)
  if #paths == 0 then
    return {}
  end

  local git_root = cached_git_root()
  local open_buffers = buffers_by_abs()

  local entries = {}
  for _, path in ipairs(paths) do
    if type(path) == "string" and vim.trim(path) ~= "" then
      local abs = to_abs(path, git_root)
      table.insert(entries, { path = path, abs = abs, bufnr = open_buffers[abs] })
    end
  end

  return entries
end

---@param file_path string
---@return string
local function not_a_chat_error(file_path)
  return string.format(
    "%s is not a vibing.nvim chat file. file_path addresses chat files only - "
      .. "use nvim_load_buffer to read an ordinary file.",
    file_path
  )
end

---パスからチャットバッファ番号を得る。開かれていなければ背景で開く（`back` と同じく窓なし）
---
---チャットでないファイルは開かずに断る。ここを通ったパスには `## User` が書き込まれうるので、
---ユーザーが編集中のソースファイルを宛先にできてしまうと、送信そのものが破壊的操作になる
---@param file_path string
---@return number bufnr
function M.open(file_path)
  if type(file_path) ~= "string" or vim.trim(file_path) == "" then
    error("file_path must be a non-empty string")
  end
  file_path = vim.trim(file_path)

  local abs = to_abs(file_path, cached_git_root())
  if not abs then
    error("Could not resolve file_path: " .. file_path)
  end

  local view = require("vibing.presentation.chat.view")
  local Frontmatter = require("vibing.infrastructure.storage.frontmatter")

  local bufnr = buffers_by_abs()[abs]

  if bufnr then
    -- 開いてはいるがロードされていないバッファ（`bufadd` だけされた等）がありうる。
    -- 中身が無いと frontmatter 判定もアタッチも空振りする
    if not vim.api.nvim_buf_is_loaded(bufnr) then
      vim.fn.bufload(bufnr)
    end
  else
    if vim.fn.filereadable(abs) == 0 then
      error(string.format("No file at %s (resolved from file_path %s)", abs, file_path))
    end
    -- バッファを作る**前**に中身で判定する。作ってから断ると、拒否した呼び出しが
    -- 無関係なバッファを1つ残していく
    if not Frontmatter.is_vibing_chat_file(abs) then
      error(not_a_chat_error(file_path))
    end

    bufnr = vim.fn.bufadd(abs)
    if bufnr == 0 then
      error("Could not create a buffer for " .. file_path)
    end
    vim.fn.bufload(bufnr)
    -- 中身は `is_vibing_chat_file` で確かめたばかり。これは `is_vibing_chat_buffer` が
    -- 最初に見るキャッシュなので、立てておけば下の判定が同じ200行を読み直さずに済む
    vim.b[bufnr].vibing_is_chat_buffer = true
  end

  if not view.get_chat_buffer(bufnr) then
    if not Frontmatter.is_vibing_chat_buffer(bufnr) then
      error(not_a_chat_error(file_path))
    end
    local ok = pcall(view.attach_to_buffer, bufnr, abs)
    if not ok then
      error("Could not attach a chat buffer for " .. file_path)
    end
  end

  -- `back` で作ったチャットと同じく `:ls` に出す（`ChatBuffer:_create_buffer` は
  -- `nvim_create_buf(true, false)`）。モデルが動かしているチャットがどこにも現れないと、
  -- ユーザーはそれを読むことも閉じることもできない。
  --
  -- 作った場合だけでは足りない。`vim.fn.bufadd` は**リストされない**バッファを作るので、
  -- `auto_resume` や `nvim_dap` が先に開いたチャットを再利用するとまさにその状態になる。
  -- チャットだと確かめ終えたここに置くことで、両方の経路が揃う
  vim.bo[bufnr].buflisted = true

  return bufnr
end

return M
