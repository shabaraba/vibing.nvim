---@class Vibing.OutputBuffer
---@field buf number? バッファ番号、未作成の場合はnil
---@field win number? ウィンドウ番号、未作成の場合はnil
local OutputBuffer = {}
OutputBuffer.__index = OutputBuffer

---新しいOutputBufferインスタンスを作成
---インライン操作（Explain, Fix, Feature等）の出力表示に使用
---@return Vibing.OutputBuffer 新しいインスタンス
function OutputBuffer:new()
  local instance = setmetatable({}, OutputBuffer)
  instance.buf = nil
  instance.win = nil
  return instance
end

---出力ウィンドウを開く
---フローティングウィンドウとして画面中央に表示
---バッファ作成、ウィンドウ表示、キーマップ設定を実行
---@param title string ウィンドウタイトル（例: "Explain Code", "Fix Code"）
function OutputBuffer:open(title)
  self:_create_buffer(title)
  self:_create_window()
  self:_setup_keymaps()
end

---ウィンドウを閉じる
---ウィンドウが有効な場合のみクローズし、winフィールドをnilに設定
---バッファ自体は削除しないため、再度open()で同じ内容を表示可能
function OutputBuffer:close()
  if self.win and vim.api.nvim_win_is_valid(self.win) then
    vim.api.nvim_win_close(self.win, true)
  end
  self.win = nil
end

---ウィンドウが開いているか
---@return boolean ウィンドウが有効かつ開いている場合true
function OutputBuffer:is_open()
  return self.win ~= nil and vim.api.nvim_win_is_valid(self.win)
end

---バッファを作成
---読み取り専用のMarkdown形式バッファとして作成
---vibing://titleの形式でバッファ名を設定
---初期コンテンツとして"# title"と"Loading..."を表示
---@param title string バッファタイトル（バッファ名とヘッダーに使用）
function OutputBuffer:_create_buffer(title)
  self.buf = vim.api.nvim_create_buf(false, true)
  vim.bo[self.buf].filetype = "markdown"
  vim.bo[self.buf].buftype = "nofile"
  vim.bo[self.buf].modifiable = true
  vim.bo[self.buf].swapfile = false
  vim.api.nvim_buf_set_name(self.buf, "vibing://" .. title)

  -- タイトルを設定
  vim.api.nvim_buf_set_lines(self.buf, 0, -1, false, {
    "# " .. title,
    "",
    "Loading...",
  })
end

---フローティングウィンドウを作成
---画面サイズの60%の幅と高さで画面中央に配置
---rounded borderとVibing タイトルを設定
---word wrap有効でmarkdown表示に適した設定
function OutputBuffer:_create_window()
  local width = math.floor(vim.o.columns * 0.6)
  local height = math.floor(vim.o.lines * 0.6)
  local row = math.floor((vim.o.lines - height) / 2)
  local col = math.floor((vim.o.columns - width) / 2)

  self.win = vim.api.nvim_open_win(self.buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    style = "minimal",
    border = "rounded",
    title = " Vibing ",
    title_pos = "center",
  })

  vim.wo[self.win].wrap = true
  vim.wo[self.win].linebreak = true
end

---キーマップを設定
---出力バッファ専用のキーマップを登録
---q, Esc: ウィンドウを閉じる
function OutputBuffer:_setup_keymaps()
  vim.keymap.set("n", "q", function()
    self:close()
  end, { buffer = self.buf, desc = "Close output" })

  vim.keymap.set("n", "<Esc>", function()
    self:close()
  end, { buffer = self.buf, desc = "Close output" })
end

---コンテンツを設定
---バッファの3行目以降（タイトル行と空行の後）を指定されたコンテンツで置き換え
---非ストリーミングモードでの一括出力に使用
---@param content string 設定するコンテンツ（改行で複数行に分割される）
function OutputBuffer:set_content(content)
  if not self.buf or not vim.api.nvim_buf_is_valid(self.buf) then
    return
  end

  local lines = vim.split(content, "\n", { plain = true })
  vim.api.nvim_buf_set_lines(self.buf, 2, -1, false, lines)
end

---ストリーミングチャンクを追加
---ストリーミング応答の各チャンクをバッファ末尾に追記
---改行を含むチャンクは複数行として処理
---最初のチャンク受信時は"Loading..."を削除
---@param chunk string 追加するテキストチャンク
---@param is_first boolean 最初のチャンクかどうか（trueの場合Loading...を削除）
function OutputBuffer:append_chunk(chunk, is_first)
  if not self.buf or not vim.api.nvim_buf_is_valid(self.buf) then
    return
  end

  if is_first then
    -- "Loading..."を削除
    vim.api.nvim_buf_set_lines(self.buf, 2, -1, false, { "" })
  end

  local lines = vim.api.nvim_buf_get_lines(self.buf, 0, -1, false)
  local last_line = lines[#lines] or ""

  local chunk_lines = vim.split(chunk, "\n", { plain = true })
  chunk_lines[1] = last_line .. chunk_lines[1]

  vim.api.nvim_buf_set_lines(self.buf, #lines - 1, #lines, false, chunk_lines)
end

---エラーを表示
---バッファの3行目以降をエラーメッセージで置き換え
---Markdown bold形式（**Error:**）でエラーを強調表示
---@param error_msg string 表示するエラーメッセージ
function OutputBuffer:show_error(error_msg)
  if not self.buf or not vim.api.nvim_buf_is_valid(self.buf) then
    return
  end

  vim.api.nvim_buf_set_lines(self.buf, 2, -1, false, {
    "",
    "**Error:**",
    "",
    error_msg,
  })
end

return OutputBuffer
