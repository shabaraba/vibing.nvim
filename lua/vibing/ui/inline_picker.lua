local notify = require("vibing.utils.notify")

---@class Vibing.InlinePicker
---インラインアクションピッカーUI
---左側にアクション選択メニュー、右側に追加プロンプト入力を横並びで表示
local M = {}

---@class Vibing.InlineAction
---@field name string アクション名
---@field desc string アクションの説明

---利用可能なアクション一覧
---@type Vibing.InlineAction[]
local ACTIONS = {
  { name = "fix", desc = "Fix code issues" },
  { name = "feat", desc = "Implement feature" },
  { name = "explain", desc = "Explain code" },
  { name = "refactor", desc = "Refactor code" },
  { name = "test", desc = "Generate tests" },
}

---インラインピッカーUIを表示
---@param callback function(action: string, instruction: string?) 選択後のコールバック
function M.show(callback)
  local state = {
    selected_idx = 1,
    instruction = "",
    focus = "menu", -- "menu" | "input"
  }

  -- レスポンシブレイアウト判定（120列を境に横/縦配置を切り替え）
  local is_wide = vim.o.columns >= 120
  local layout = is_wide and "horizontal" or "vertical"

  -- ウィンドウサイズを計算
  local width, height, menu_width, menu_height, input_width, input_height, menu_row, menu_col, input_row, input_col

  if layout == "horizontal" then
    -- 横並びレイアウト
    width = math.floor(vim.o.columns * 0.6)
    height = 10
    menu_width = math.floor(width * 0.4)
    input_width = width - menu_width - 3 -- 3 for borders and gap
    menu_height = height
    input_height = height

    local row = math.floor((vim.o.lines - height) / 2)
    local col = math.floor((vim.o.columns - width) / 2)

    menu_row = row
    menu_col = col
    input_row = row
    input_col = col + menu_width + 3
  else
    -- 縦並びレイアウト
    width = math.floor(vim.o.columns * 0.8)
    menu_height = 8
    input_height = 5
    height = menu_height + input_height + 3 -- 3 for gap
    menu_width = width
    input_width = width

    local row = math.floor((vim.o.lines - height) / 2)
    local col = math.floor((vim.o.columns - width) / 2)

    menu_row = row
    menu_col = col
    input_row = row + menu_height + 3
    input_col = col
  end

  -- 左側バッファ（メニュー）を作成
  local menu_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_option(menu_buf, "bufhidden", "wipe")
  vim.api.nvim_buf_set_option(menu_buf, "modifiable", false)

  -- 右側バッファ（入力）を作成
  local input_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_option(input_buf, "bufhidden", "wipe")
  vim.api.nvim_buf_set_option(input_buf, "buftype", "prompt")
  vim.fn.prompt_setprompt(input_buf, "> ")

  -- メニューウィンドウを作成
  local menu_win = vim.api.nvim_open_win(menu_buf, false, {
    relative = "editor",
    width = menu_width,
    height = menu_height,
    row = menu_row,
    col = menu_col,
    style = "minimal",
    border = "rounded",
    title = " Action ",
    title_pos = "center",
  })

  -- 入力ウィンドウを作成
  local input_win = vim.api.nvim_open_win(input_buf, false, {
    relative = "editor",
    width = input_width,
    height = input_height,
    row = input_row,
    col = input_col,
    style = "minimal",
    border = "rounded",
    title = " Additional Instruction (optional) ",
    title_pos = "center",
  })

  -- メニュー描画関数
  local function render_menu()
    vim.api.nvim_buf_set_option(menu_buf, "modifiable", true)
    local lines = {}
    table.insert(lines, "")
    for i, action in ipairs(ACTIONS) do
      local prefix = i == state.selected_idx and "▶ " or "  "
      table.insert(lines, string.format("%s%s - %s", prefix, action.name, action.desc))
    end
    table.insert(lines, "")

    -- レイアウトに応じたヘルプテキスト
    if layout == "horizontal" then
      table.insert(lines, "Tab: Move to input | Enter: Execute | Esc: Cancel")
    else
      table.insert(lines, "Tab: Move to input ↓ | Enter: Execute | Esc: Cancel")
    end

    vim.api.nvim_buf_set_lines(menu_buf, 0, -1, false, lines)
    vim.api.nvim_buf_set_option(menu_buf, "modifiable", false)

    -- 選択中の行をハイライト
    local ns_id = vim.api.nvim_create_namespace("vibing_inline_picker")
    vim.api.nvim_buf_clear_namespace(menu_buf, ns_id, 0, -1)
    vim.api.nvim_buf_add_highlight(menu_buf, ns_id, "Visual", state.selected_idx, 0, -1)
  end

  -- 初期描画
  render_menu()

  -- フォーカス切り替え関数
  local function set_focus(focus_target)
    state.focus = focus_target
    if focus_target == "menu" then
      vim.api.nvim_set_current_win(menu_win)
      -- メニューウィンドウを強調表示
      vim.api.nvim_win_set_option(menu_win, "winhl", "Normal:Normal,FloatBorder:FloatBorder")
      vim.api.nvim_win_set_option(input_win, "winhl", "Normal:NormalNC,FloatBorder:FloatBorderNC")
    else
      vim.api.nvim_set_current_win(input_win)
      -- 入力ウィンドウを強調表示
      vim.api.nvim_win_set_option(menu_win, "winhl", "Normal:NormalNC,FloatBorder:FloatBorderNC")
      vim.api.nvim_win_set_option(input_win, "winhl", "Normal:Normal,FloatBorder:FloatBorder")
      -- カーソルを入力の最後に移動
      vim.cmd("startinsert")
    end
  end

  -- メニューのキーマップ設定
  local function set_menu_keymaps()
    local opts = { buffer = menu_buf, nowait = true, silent = true }

    -- 上下移動
    vim.keymap.set("n", "j", function()
      state.selected_idx = math.min(state.selected_idx + 1, #ACTIONS)
      render_menu()
    end, opts)

    vim.keymap.set("n", "k", function()
      state.selected_idx = math.max(state.selected_idx - 1, 1)
      render_menu()
    end, opts)

    vim.keymap.set("n", "<Down>", function()
      state.selected_idx = math.min(state.selected_idx + 1, #ACTIONS)
      render_menu()
    end, opts)

    vim.keymap.set("n", "<Up>", function()
      state.selected_idx = math.max(state.selected_idx - 1, 1)
      render_menu()
    end, opts)

    -- Tab: 入力フィールドに移動
    vim.keymap.set("n", "<Tab>", function()
      set_focus("input")
    end, opts)

    -- Enter: 実行
    vim.keymap.set("n", "<CR>", function()
      -- 入力フィールドの内容を取得
      local lines = vim.api.nvim_buf_get_lines(input_buf, 0, -1, false)
      local instruction = ""
      for _, line in ipairs(lines) do
        -- プロンプトプレフィックス（"> "）を除去
        local text = line:gsub("^> ", "")
        if text ~= "" then
          instruction = instruction .. text
        end
      end

      -- ウィンドウを閉じる
      if vim.api.nvim_win_is_valid(menu_win) then
        vim.api.nvim_win_close(menu_win, true)
      end
      if vim.api.nvim_win_is_valid(input_win) then
        vim.api.nvim_win_close(input_win, true)
      end

      -- コールバック実行
      local selected_action = ACTIONS[state.selected_idx].name
      callback(selected_action, instruction ~= "" and instruction or nil)
    end, opts)

    -- Esc/Ctrl-c: キャンセル
    local function close_picker()
      if vim.api.nvim_win_is_valid(menu_win) then
        vim.api.nvim_win_close(menu_win, true)
      end
      if vim.api.nvim_win_is_valid(input_win) then
        vim.api.nvim_win_close(input_win, true)
      end
    end

    vim.keymap.set("n", "<Esc>", close_picker, opts)
    vim.keymap.set("n", "<C-c>", close_picker, opts)
  end

  -- 入力フィールドのキーマップ設定
  local function set_input_keymaps()
    local opts = { buffer = input_buf, nowait = true, silent = true }

    -- Shift-Tab: メニューに戻る
    vim.keymap.set({ "i", "n" }, "<S-Tab>", function()
      set_focus("menu")
    end, opts)

    -- Ctrl-c: キャンセル
    vim.keymap.set({ "i", "n" }, "<C-c>", function()
      if vim.api.nvim_win_is_valid(menu_win) then
        vim.api.nvim_win_close(menu_win, true)
      end
      if vim.api.nvim_win_is_valid(input_win) then
        vim.api.nvim_win_close(input_win, true)
      end
    end, opts)

    -- Enter: 実行
    vim.keymap.set({ "i", "n" }, "<CR>", function()
      -- 入力フィールドの内容を取得
      local lines = vim.api.nvim_buf_get_lines(input_buf, 0, -1, false)
      local instruction = ""
      for _, line in ipairs(lines) do
        -- プロンプトプレフィックス（"> "）を除去
        local text = line:gsub("^> ", "")
        if text ~= "" then
          instruction = instruction .. text
        end
      end

      -- ウィンドウを閉じる
      if vim.api.nvim_win_is_valid(menu_win) then
        vim.api.nvim_win_close(menu_win, true)
      end
      if vim.api.nvim_win_is_valid(input_win) then
        vim.api.nvim_win_close(input_win, true)
      end

      -- コールバック実行
      local selected_action = ACTIONS[state.selected_idx].name
      callback(selected_action, instruction ~= "" and instruction or nil)
    end, opts)
  end

  -- キーマップを設定
  set_menu_keymaps()
  set_input_keymaps()

  -- 初期フォーカスをメニューに設定
  set_focus("menu")
end

return M
