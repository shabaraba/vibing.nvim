---@class Vibing.Utils.FilePath
---ファイルパス検出と操作のユーティリティ
local M = {}

local BufferIdentifier = require("vibing.core.utils.buffer_identifier")

---相対パスの解決基準。チャットの working_dir を優先する（worktree に紐づいたチャットでは
---Neovim の cwd が一致しない）
---@param buf number チャットバッファ番号
---@return string
local function chat_cwd(buf)
  local ChatView = require("vibing.presentation.chat.view")
  local chat_buf = ChatView.get_chat_buffer(buf)
  return chat_buf and chat_buf:get_cwd() or vim.fn.getcwd()
end

---カーソルが "### Modified Files" セクション内のファイルパス上にあるかチェック
---現在行がファイルパスであり、かつ "### Modified Files" セクション内にある場合、ファイルパスを返す
---@param buf number バッファ番号
---@return string? ファイルパス（セクション内のファイルパス上にない場合は nil）
function M.is_cursor_on_file_path(buf)
  local cursor = vim.api.nvim_win_get_cursor(0)
  local row = cursor[1]
  local total_lines = vim.api.nvim_buf_line_count(buf)

  -- 現在行の内容を取得
  local current_line = vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1]
  if not current_line or current_line == "" then
    return nil
  end

  -- ファイルパスの形式をチェック（空白をトリム）
  local trimmed_line = current_line:match("^%s*(.-)%s*$")
  if not trimmed_line or trimmed_line == "" then
    return nil
  end

  -- "##" または "###" で始まる行はヘッダーなので除外
  if trimmed_line:match("^###?") then
    return nil
  end

  -- `### Modified Files` の1行サマリ（`3 files changed: a.lua, b.lua`）。パスではないので、
  -- ここで弾かないと `<cwd>/3 files changed: ...` という存在しないパスを返してしまう。
  -- 弾いた結果 `gf` は `<cfile>` 経路に回り、サマリ内のファイル名の上なら普通に開ける
  if trimmed_line:match("^%d+ files? changed: ") then
    return nil
  end

  -- `Patch: /path/to.patch` も同様。行そのものはパスではないので弾き、`<cfile>` 経路に回す。
  -- そうするとパスの上で `gf` を押せばpatchファイルが普通に開く
  if trimmed_line:match("^Patch:%s") then
    return nil
  end

  -- 後方に "### Modified Files" ヘッダーを探す
  local found_modified_files_header = false
  for i = row - 1, 1, -1 do
    local line = vim.api.nvim_buf_get_lines(buf, i - 1, i, false)[1]
    if line then
      if line:match("^###%s+Modified%s+Files") then
        found_modified_files_header = true
        break
      elseif line:match("^###%s+") and not line:match("^###%s+Modified%s+Files") then
        -- 別のH3セクションヘッダーに到達したので、Modified Filesセクション外
        return nil
      elseif line:match("^##%s+") then
        -- H2セクションヘッダーに到達したので、Modified Filesセクション外
        return nil
      end
    end
  end

  if not found_modified_files_header then
    return nil
  end

  -- 前方に次のセクションヘッダー（H2またはH3）があるかチェック
  for i = row + 1, total_lines do
    local line = vim.api.nvim_buf_get_lines(buf, i - 1, i, false)[1]
    if line and line:match("^###?%s+") then
      -- 次のセクションに到達したので、Modified Filesセクション内ではない
      break
    end
  end

  -- Check if this is a [Buffer N] identifier
  if BufferIdentifier.is_buffer_identifier(trimmed_line) then
    -- Extract buffer number and check if buffer exists
    local bufnr = BufferIdentifier.extract_bufnr(trimmed_line)
    if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
      return trimmed_line  -- Return as-is, don't normalize
    end
    return nil
  end

  -- ファイルの存在確認
  -- frontmatterのworking_dirを考慮してファイルパスを解決
  local cwd = chat_cwd(buf)

  -- 相対パスの場合はworking_dir基準で解決
  local file_path
  if trimmed_line:sub(1, 1) == "/" then
    -- 絶対パスの場合はそのまま使用
    file_path = trimmed_line
  else
    -- 相対パスの場合はworking_dir基準で解決
    file_path = vim.fn.fnamemodify(cwd .. "/" .. trimmed_line, ":p")
  end

  -- ファイルが存在する場合はそのまま返す
  if vim.fn.filereadable(file_path) == 1 or vim.fn.isdirectory(file_path) == 1 then
    return file_path
  end

  -- ファイルが存在しない場合でも、Modified Filesセクション内であれば
  -- 削除されたファイルの可能性があるため、パスを返す
  -- （patch previewで表示可能）
  return file_path
end

---リンク先から `#L42` / `:42` の行指定を切り離す。
---`..-` は「1文字以上の最短一致」で、`#L3` のようなパス部分が空の綴りを除く
---@param dest string
---@return string path
---@return number? lnum
local function split_line_suffix(dest)
  local path, lnum = dest:match("^(..-)#L(%d+)$")
  if not path then
    path, lnum = dest:match("^(..-):(%d+)$")
  end
  if path then
    return path, tonumber(lnum)
  end
  return dest, nil
end

---Markdown リンク先を実在する絶対パスへ解決する。
---行指定・アンカー・それらをファイル名に含むパスは、ファイルシステムに聞くまで区別が
---つかないので、候補を順に並べて最初に実在したものを採る。
---@param dest string リンク先
---@param cwd string? 相対パスの解決基準（チャットの working_dir）
---@return string? 実在する絶対パス
---@return number? リンク先が指定していた行番号
function M.resolve_link_dest(dest, cwd)
  local PathResolve = require("vibing.core.utils.path_resolve")
  local path, lnum = split_line_suffix(dest)

  -- 1. 行指定を外したパス 2. 外す前（`a:42` という名前のファイル）3. アンカーを外したパス
  for i, candidate in ipairs({ path, dest, (path:gsub("#.*$", "")) }) do
    local resolved = PathResolve.existing_file(candidate, cwd)
    if resolved then
      return resolved, i == 1 and lnum or nil
    end
  end
  return nil
end

---カーソル下の Markdown インラインリンク `[label](path)` のリンク先を解決する。
---ラベル・括弧・リンク先のどこにカーソルがあっても同じ結果になる（`gx` と同じ扱い）。
---
---URL は `gx` の領分なので返さない。実在しないパスも返さない — `gf` はこの後 `<cfile>`
---経路に回るので、ここで握り潰すと今まで開けていたものが開けなくなる。
---@param buf number チャットバッファ番号
---@return string? 実在する絶対パス
---@return number? リンク先が指定していた行番号
function M.find_link_target_under_cursor(buf)
  local MarkdownLink = require("vibing.core.utils.markdown_link")

  local cursor = vim.api.nvim_win_get_cursor(0)
  local line = vim.api.nvim_buf_get_lines(buf, cursor[1] - 1, cursor[1], false)[1]
  local dest = line and MarkdownLink.find_at(line, cursor[2] + 1)
  if not dest or MarkdownLink.classify(dest) ~= "path" then
    return nil
  end

  -- `chat_cwd` は git を起動する。絶対パスなら要らないので、ここまで判定を済ませてから呼ぶ
  local cwd = dest:sub(1, 1) ~= "/" and chat_cwd(buf) or nil
  return M.resolve_link_dest(dest, cwd)
end

---ファイルを開く
---既に開かれている場合はそのバッファに切り替え、そうでない場合は新規に開く
---@param file_path string ファイルパス（絶対パス）または[Buffer N]形式
---@param lnum number? 開いた後にジャンプする行番号
function M.open_file(file_path, lnum)
  -- Check if this is a [Buffer N] identifier
  if BufferIdentifier.is_buffer_identifier(file_path) then
    local bufnr = BufferIdentifier.extract_bufnr(file_path)
    if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_set_current_buf(bufnr)
    else
      vim.notify("[vibing] Buffer not found: " .. file_path, vim.log.levels.ERROR)
    end
    return
  end

  -- ファイルの存在確認
  if vim.fn.filereadable(file_path) == 0 then
    vim.notify("[vibing] File not found: " .. file_path, vim.log.levels.ERROR)
    return
  end

  -- 既に開かれているバッファがあるか確認
  local buf = vim.fn.bufnr(file_path)
  if buf ~= -1 then
    -- 既存のバッファに切り替え
    vim.api.nvim_set_current_buf(buf)
  else
    -- 新規に開く
    vim.cmd.edit(vim.fn.fnameescape(file_path))
  end

  if lnum then
    -- nvim_win_set_cursor は ' マークも jumplist も更新しないので明示的に積む。
    -- `gf` はモーションなので、これが無いと <C-o> で元の位置へ戻れない
    vim.cmd("normal! m'")
    pcall(vim.api.nvim_win_set_cursor, 0, { math.min(lnum, vim.api.nvim_buf_line_count(0)), 0 })
    vim.cmd("normal! zz")
  end
end

return M
