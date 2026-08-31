---@class Vibing.Application.Chat.OrchestrationLink
---チャット同士のオーケストレーション関係を、双方の frontmatter に記録する。
---
---関係の唯一の記録がトランスクリプトの地の文だったのが元の状態で、それは二重に壊れる。
---bufnr は Neovim を再起動すれば別のバッファを指し、`:VibingSetFileTitle` はチャット
---ファイルを改名するので、書き残したパスは黙って腐る。`forked_from` が frontmatter +
---`ForkedChatScanner` で既に解いている問題なので、同じ形に揃える。
---
---方向を `orchestrated` / `orchestrated_by` の2フィールドに分けているのは、ワーカー側が
---「自分に指示を出したのは誰か」を答えられる必要があるため。隣のワーカーと区別のつかない
---フラットな集合では、そこに答えられない。
local M = {}

local Git = require("vibing.core.utils.git")
local FileManager = require("vibing.presentation.chat.modules.file_manager")

---`Git.get_root()` はキャッシュを持たず、毎回 `vim.system():wait()` で同期的に
---`git rev-parse` を起動する。`resolve_bufnrs` はワーカーチャットの**送信のたび**に呼ばれるので、
---そのままではユーザーの `<CR>` の前でメインスレッドがプロセス起動1回分ブロックする。
---値はcwdごとに固定なので、cwdをキーに覚える
---@type table<string, string|false>
local git_root_by_cwd = {}

---@return string|false
local function cached_git_root()
  local cwd = vim.fn.getcwd()
  if git_root_by_cwd[cwd] == nil then
    git_root_by_cwd[cwd] = Git.get_root() or false
  end
  return git_root_by_cwd[cwd]
end

---@param bufnr number
---@return table? chat_buf
local function resolve_chat(bufnr)
  if type(bufnr) ~= "number" or not vim.api.nvim_buf_is_valid(bufnr) then
    return nil
  end
  return require("vibing.presentation.chat.view").get_chat_buffer(bufnr)
end

---A が B に指示を出した関係を両者の frontmatter に書く
---
---呼び出しは `ProgrammaticSender.send` より**前**に済ませること。
---`update_frontmatter_list` はバッファを直接編集するので、B の応答が始まってから書くと
---ストリーミングと競合する。
---@param from_bufnr number 送信元（オーケストレーター側）
---@param to_bufnr number 送信先（ワーカー側）
---@return boolean success
---@return string? error
function M.link(from_bufnr, to_bufnr)
  if from_bufnr == to_bufnr then
    return false, "A chat cannot orchestrate itself"
  end

  local from_chat = resolve_chat(from_bufnr)
  local to_chat = resolve_chat(to_bufnr)
  if not from_chat or not to_chat then
    return false, "Both buffers must be vibing chat buffers"
  end

  local from_path = vim.api.nvim_buf_get_name(from_bufnr)
  local to_path = vim.api.nvim_buf_get_name(to_bufnr)
  if from_path == "" or to_path == "" then
    return false, "Both chats must have a file name"
  end

  local forward = Git.to_display_path(to_path)
  local backward = Git.to_display_path(from_path)

  -- スキルは `nvim_chat_create` と続く `nvim_chat_send_message` の両方に `from_bufnr` を渡すので、
  -- 同じリンクが2回書かれる。`update_frontmatter_list` は要素としては重複を弾くが、行の書き換えと
  -- `updated_at` の更新でバッファを modified にするため、そのあと両チャットの全文が書き直される
  if
    vim.tbl_contains(from_chat:get_frontmatter_list("orchestrated"), forward)
    and vim.tbl_contains(to_chat:get_frontmatter_list("orchestrated_by"), backward)
  then
    return true, nil
  end

  -- 戻り値を捨ててはいけない。`update_frontmatter_list` は frontmatter の閉じ `---` が
  -- 先頭100行に収まらないと false を返す（長い permission 配列を持つチャットで現実に起きる）。
  -- 捨てると、このモジュールが防ぐために存在している「黙って関係が残らない」がそのまま起きる
  if not from_chat:update_frontmatter_list("orchestrated", forward, "add") then
    return false, "Could not record the worker in the orchestrator's frontmatter"
  end
  if not to_chat:update_frontmatter_list("orchestrated_by", backward, "add") then
    return false, "Could not record the orchestrator in the worker's frontmatter"
  end

  -- `update_frontmatter_list` はバッファにしか書かない。リネーム同期はディスクを読むので、
  -- ここで保存しないとリンクは「次に何かの理由で保存されるまで」存在しないことになる。
  -- 送信元は `:VibingChat` の性質上まだ一度も保存されていないことがあり、その窓がいちばん
  -- 長い（＝1ターン目に投げた相手が改名されるとリンクが片方向に腐る）
  local saved_from = FileManager.save_buffer(from_bufnr)
  local saved_to = FileManager.save_buffer(to_bufnr)
  if not (saved_from and saved_to) then
    return false, "Wrote the orchestration link but could not save both chat files"
  end

  return true, nil
end

---frontmatter に記録された表示パスを、いま開いているチャットバッファ番号に解決する
---
---frontmatter がパスを持つのはそれが唯一セッションを越えて意味を保つ形だからだが、
---`nvim_chat_send_message` が受け取るのは bufnr なので、モデルに渡すにはここで引き直す
---必要がある。開かれていないチャットは番号を持たないので単に落ちる
---@param display_paths string[]?
---@return number[]
function M.resolve_bufnrs(display_paths)
  -- 手で `orchestrated_by: path.md` と1行で書かれると文字列としてパースされる形も含めて、
  -- リストフィールドの3つの形は `Frontmatter.as_list` が吸収する
  local paths = require("vibing.infrastructure.storage.frontmatter").as_list(display_paths)
  if #paths == 0 then
    return {}
  end

  -- 比較は両側ともシンボリックリンクを解決した形で行う。`nvim_buf_get_name` は解決済みの
  -- パスを返すので（macOSでは `/var/...` が `/private/var/...` になる）、`:p` だけでは
  -- 同じファイルが一致しない
  local PathSanitizer = require("vibing.domain.security.path_sanitizer")

  local git_root = cached_git_root()
  local wanted = {}
  for _, path in ipairs(paths) do
    if type(path) == "string" and path ~= "" then
      wanted[PathSanitizer.normalize(Git.from_display_path(path, git_root))] = true
    end
  end

  local resolved = {}
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      local name = vim.api.nvim_buf_get_name(bufnr)
      if name ~= "" and wanted[PathSanitizer.normalize(name)] then
        table.insert(resolved, bufnr)
      end
    end
  end

  table.sort(resolved)
  return resolved
end

return M
