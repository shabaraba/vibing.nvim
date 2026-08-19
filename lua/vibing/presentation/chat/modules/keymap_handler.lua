local Context = require("vibing.application.context.manager")

local M = {}

-- URL 本体はできるだけ広くマッチさせ（空白と、URL でまず生では使われない
-- `< > " ' バッククォート` のみを区切りとする）、末尾の Markdown 装飾・句読点・
-- 対応の取れていない閉じ括弧だけを後から削る。括弧類を文字クラスから除外する
-- 方式だと、IPv6 の `https://[2001:db8::1]/` や `/foo_(bar)`・`/a*b` のような
-- 括弧・アスタリスクを含む正当な URL まで途中で切ってしまうため。
local URL_PAT = "(https?://[^ \t\n<>\"'`]+)"

-- 末尾から削る Markdown 装飾（**bold**, `code`）と句読点
local TRAILING_PUNCT_PAT = "[%*`.,;:!?]+$"

-- 閉じ括弧 → 対応する開き括弧
local CLOSERS = { [")"] = "(", ["]"] = "[", ["}"] = "{" }

---文字列中に特定の1文字が現れる回数を数える（Lua パターンのエスケープを避けるため素朴に走査）
---@param s string
---@param ch string 1文字
---@return number
local function count_char(s, ch)
  local n = 0
  for i = 1, #s do
    if s:sub(i, i) == ch then
      n = n + 1
    end
  end
  return n
end

---URL 末尾の Markdown 装飾・句読点・対応の取れていない閉じ括弧を安定するまで削る。
---`Foo_(bar)` のように括弧が対応している場合は保持する。
---@param url string
---@return string
local function trim_url(url)
  while true do
    local before = url
    url = url:gsub(TRAILING_PUNCT_PAT, "")
    local last = url:sub(-1)
    local opener = CLOSERS[last]
    if opener and count_char(url, last) > count_char(url, opener) then
      url = url:sub(1, -2)
    end
    if url == before then
      break
    end
  end
  return url
end

---行内からカーソル位置（1-indexed）に対応する URL を探す。
---カーソルが URL 上にあればそれを、なければ最も近い URL を（max_dist 以内で）返す。
---@param line string 行全体
---@param col number カーソルの 1-indexed カラム
---@return string|nil
function M.find_url_on_line(line, col)
  local found_url = nil
  local best_dist = math.huge
  local max_dist = 10

  local search_pos = 1
  while true do
    local url_start, raw_end, url = line:find(URL_PAT, search_pos)
    if not url_start then
      break
    end

    url = trim_url(url)
    local url_end = url_start + #url - 1

    if col >= url_start and col <= url_end then
      return url
    end
    local dist = math.min(math.abs(col - url_start), math.abs(col - url_end))
    if dist < best_dist and dist <= max_dist then
      best_dist = dist
      found_url = url
    end
    -- 広くマッチした範囲全体をスキップ（トリムした末尾を再走査しない）
    search_pos = raw_end + 1
  end

  return found_url
end

---キーマップを設定
---@param buf number バッファ番号
---@param callbacks table コールバック関数テーブル
---@param keymaps table キーマップ設定
function M.setup(buf, callbacks, keymaps)
  local function set_keymaps()
    if not vim.api.nvim_buf_is_valid(buf) then
      return
    end

    pcall(vim.keymap.del, "n", keymaps.send, { buffer = buf })

    vim.keymap.set("n", keymaps.send, function()
      if callbacks.send_message then
        callbacks.send_message()
      end
    end, { buffer = buf, desc = "Send message" })

    vim.keymap.set("n", keymaps.cancel, function()
      if callbacks.cancel then
        callbacks.cancel()
      end
    end, { buffer = buf, desc = "Cancel request" })

    vim.keymap.set("n", keymaps.add_context, function()
      vim.ui.input({ prompt = "Add context: ", completion = "file" }, function(path)
        if path then
          Context.add(path)
          if callbacks.update_context_line then
            callbacks.update_context_line()
          end
        end
      end)
    end, { buffer = buf, desc = "Add context" })

    vim.keymap.set("n", keymaps.open_diff, function()
      local FilePath = require("vibing.core.utils.file_path")
      local PatchFinder = require("vibing.presentation.chat.modules.patch_finder")
      local PatchViewer = require("vibing.ui.patch_viewer")
      local view = require("vibing.presentation.chat.view")

      local file_path = FilePath.is_cursor_on_file_path(buf)
      if not file_path then
        vim.notify("No file path under cursor", vim.log.levels.INFO)
        return
      end

      -- patchファイル方式で表示を試みる
      local session_id = PatchFinder.get_session_id(buf)
      local patch_filename = PatchFinder.find_nearest_patch(buf)

      if session_id and patch_filename then
        -- patchファイルから該当ファイルのdiffを表示
        PatchViewer.show(session_id, patch_filename, file_path)
      else
        -- patchがない場合は送信時と同じ規則でdiffバックエンドを選択
        -- （diff.tool = "mote" またはmote_dirs該当ならmote、それ以外はgit diff）
        local DiffSelector = require("vibing.core.utils.diff_selector")
        -- cwd・mote_dirsをチャットのfrontmatterから取得
        local cwd = nil
        local mote_dirs = nil
        local chat_buf = view.get_chat_buffer(buf)
        if chat_buf then
          cwd = chat_buf:get_cwd()
          local frontmatter = chat_buf:parse_frontmatter()
          mote_dirs = frontmatter and frontmatter.mote_dirs
          if type(mote_dirs) == "string" then
            mote_dirs = { mote_dirs }
          end
          if (not mote_dirs or #mote_dirs == 0) and frontmatter and frontmatter.mote_cwd then
            mote_dirs = { frontmatter.mote_cwd }
          end
        end
        DiffSelector.show_diff(file_path, session_id, cwd, mote_dirs)
      end
    end, { buffer = buf, desc = "Open diff for file under cursor" })

    vim.keymap.set("n", keymaps.open_file, function()
      local FilePath = require("vibing.core.utils.file_path")
      local file_path = FilePath.is_cursor_on_file_path(buf)
      if file_path then
        FilePath.open_file(file_path)
      else
        -- Modified Files セクション外では <cfile> で検出したパスを使う
        local cfile = vim.fn.expand("<cfile>")
        if cfile ~= "" then
          local expanded = vim.fn.expand(cfile)
          if vim.fn.filereadable(expanded) == 1 then
            FilePath.open_file(expanded)
          end
        end
      end
    end, { buffer = buf, desc = "Open file under cursor" })

    vim.keymap.set("n", keymaps.open_url, function()
      if not vim.ui.open then
        vim.notify("vim.ui.open requires Neovim 0.10+", vim.log.levels.WARN)
        return
      end
      -- バッファ行全体を取得（ソフト折り返し時も完全なURLを取得できる）
      local line = vim.fn.getline(".")
      local col = vim.api.nvim_win_get_cursor(0)[2] + 1 -- 1-indexed

      local found_url = M.find_url_on_line(line, col)

      if found_url then
        local err = vim.ui.open(found_url)
        if err then
          vim.notify("Failed to open URL: " .. tostring(err), vim.log.levels.ERROR)
        end
      else
        vim.notify("No URL found on current line", vim.log.levels.INFO)
      end
    end, { buffer = buf, desc = "Open URL on current line" })

    -- NOTE: gp (preview all) was removed - use gd on individual files in Modified Files section
    -- Diff display now uses patch files in .vibing/patches/<session_id>/

    vim.keymap.set("n", "q", function()
      if callbacks.close then
        callbacks.close()
      end
    end, { buffer = buf, desc = "Close chat" })
  end

  set_keymaps()
  vim.defer_fn(set_keymaps, 100)

  local group = vim.api.nvim_create_augroup("vibing_chat_keymaps_" .. buf, { clear = true })
  vim.api.nvim_create_autocmd({ "BufEnter", "InsertLeave", "TextChanged" }, {
    group = group,
    buffer = buf,
    callback = function()
      vim.defer_fn(set_keymaps, 10)
    end,
  })
end

return M
