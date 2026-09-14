---@class Vibing.PatchViewer.Keymaps
local M = {}

---@param state Vibing.PatchViewer.State
---@param callbacks { select_file: fun(dir: number), select_from_cursor: fun(), open_file: fun(), toggle_layout: fun(), cycle_window: fun(dir: number), revert: fun(), revert_all: fun(), close: fun() }
function M.setup(state, callbacks)
  if state.buf_files and vim.api.nvim_buf_is_valid(state.buf_files) then
    local opts = { buffer = state.buf_files, noremap = true, silent = true }

    vim.keymap.set("n", "j", function()
      callbacks.select_file(1)
    end, vim.tbl_extend("force", opts, { desc = "Next file" }))

    vim.keymap.set("n", "k", function()
      callbacks.select_file(-1)
    end, vim.tbl_extend("force", opts, { desc = "Previous file" }))

    -- 一覧の移動はj/kが即座にプレビューへ反映するので、`<CR>` は「開く」に充てる。
    -- チャットに一覧が無くなった以上、実ファイルへ行く導線はここしかない
    for _, key in ipairs({ "<CR>", "o" }) do
      vim.keymap.set("n", key, function()
        callbacks.open_file()
      end, vim.tbl_extend("force", opts, { desc = "Open the real file" }))
    end

    M._setup_common(state.buf_files, callbacks)
  end

  -- Beforeペインだけ。Afterは実ファイルのバッファなので、そこにビューア用のキーを
  -- 焼き付けるとフロートを閉じた後も残る
  if state.buf_before and vim.api.nvim_buf_is_valid(state.buf_before) then
    local opts = { buffer = state.buf_before, noremap = true, silent = true }

    vim.keymap.set("n", "<C-j>", function()
      callbacks.select_file(1)
    end, vim.tbl_extend("force", opts, { desc = "Next file" }))

    vim.keymap.set("n", "<C-k>", function()
      callbacks.select_file(-1)
    end, vim.tbl_extend("force", opts, { desc = "Previous file" }))

    M._setup_common(state.buf_before, callbacks)
  end
end

---Afterペインに焼くキー。実ファイルのバッファなので、`r` のような普段使いの1文字は奪わない。
---`s` だけは例外で、差分を読んでいる最中に表示を切り替えたくなるのはこのペインだから
local AFTER_KEYS = { "<Tab>", "<S-Tab>", "s", "q", "<Esc>" }

---Afterペインに張る前から **そのバッファに在った** マッピングを控える。
---ftpluginやユーザーのバッファローカル定義が `q` や `s` を使っていることはあり、
---外すだけでは戻らない（フロートを閉じた後も消えたままになる）
---@param buf number
---@return table[] `vim.fn.mapset` に渡せる形のまま
local function take_over(buf)
  local wanted = {}
  for _, lhs in ipairs(AFTER_KEYS) do
    wanted[vim.keycode(lhs)] = true
  end

  local saved = {}
  for _, map in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
    if wanted[vim.keycode(map.lhs)] then
      table.insert(saved, map)
    end
  end
  return saved
end

---Afterペインは選択のたびに実ファイルのバッファへ差し替わるので、キーもその都度張り直す
---@param state Vibing.PatchViewer.State
---@param buf number?
---@param callbacks table
function M.setup_after(state, buf, callbacks)
  M.clear_after(state)
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then
    return
  end

  state.after_saved_maps = take_over(buf)

  local opts = { buffer = buf, noremap = true, silent = true }
  vim.keymap.set("n", "<Tab>", function()
    callbacks.cycle_window(1)
  end, vim.tbl_extend("force", opts, { desc = "Next window" }))
  vim.keymap.set("n", "<S-Tab>", function()
    callbacks.cycle_window(-1)
  end, vim.tbl_extend("force", opts, { desc = "Previous window" }))
  vim.keymap.set("n", "s", function()
    callbacks.toggle_layout()
  end, vim.tbl_extend("force", opts, { desc = "Toggle side-by-side / unified" }))
  for _, key in ipairs({ "q", "<Esc>" }) do
    vim.keymap.set("n", key, function()
      callbacks.close()
    end, vim.tbl_extend("force", opts, { desc = "Close" }))
  end

  state.after_mapped = buf
end

---張ったキーを実ファイルのバッファから外す。怠るとフロートを閉じた後も `q` が奪われたままになる
---@param state Vibing.PatchViewer.State
function M.clear_after(state)
  local buf = state.after_mapped
  local saved = state.after_saved_maps or {}
  state.after_mapped = nil
  state.after_saved_maps = nil
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then
    return
  end
  for _, lhs in ipairs(AFTER_KEYS) do
    pcall(vim.keymap.del, "n", lhs, { buffer = buf })
  end
  -- `mapset` はカレントバッファに張るので、対象バッファの中で呼ぶ
  for _, map in ipairs(saved) do
    pcall(vim.api.nvim_buf_call, buf, function()
      vim.fn.mapset(map)
    end)
  end
end

---@param buf number
---@param callbacks { cycle_window: fun(dir: number), revert: fun(), revert_all: fun(), close: fun() }
function M._setup_common(buf, callbacks)
  local opts = { buffer = buf, noremap = true, silent = true }

  vim.keymap.set("n", "<Tab>", function()
    callbacks.cycle_window(1)
  end, vim.tbl_extend("force", opts, { desc = "Next window" }))

  vim.keymap.set("n", "<S-Tab>", function()
    callbacks.cycle_window(-1)
  end, vim.tbl_extend("force", opts, { desc = "Previous window" }))

  vim.keymap.set("n", "s", function()
    callbacks.toggle_layout()
  end, vim.tbl_extend("force", opts, { desc = "Toggle side-by-side / unified" }))

  vim.keymap.set("n", "r", function()
    callbacks.revert()
  end, vim.tbl_extend("force", opts, { desc = "Revert selected file" }))

  vim.keymap.set("n", "R", function()
    callbacks.revert_all()
  end, vim.tbl_extend("force", opts, { desc = "Revert all files in patch" }))

  vim.keymap.set("n", "q", function()
    callbacks.close()
  end, vim.tbl_extend("force", opts, { desc = "Close" }))

  vim.keymap.set("n", "<Esc>", function()
    callbacks.close()
  end, vim.tbl_extend("force", opts, { desc = "Close" }))
end

return M
