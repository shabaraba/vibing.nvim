---AskUserQuestion UI module for vibing.nvim
---Handles inline question display and selection via line deletion
---@module "vibing.ui.ask_user_question"

local notify = require("vibing.core.utils.notify")

---@class Vibing.AskUserQuestion
local M = {}

---@class Vibing.QuestionState
---@field active boolean 質問表示中か
---@field buf number? 対象バッファ
---@field question_start_line number? 質問セクション開始行
---@field question_end_line number? 質問セクション終了行
---@field question table? 現在の質問
---@field callback function? 選択完了時のコールバック
---@field original_keymaps table? 元のキーマップ（復元用）
local state = {
  active = false,
  buf = nil,
  question_start_line = nil,
  question_end_line = nil,
  question = nil,
  callback = nil,
  original_keymaps = nil,
}

---選択肢のマーカーパターン
local OPTION_MARKER_PATTERN = "<!--vibing:option:(.+)-->"

---セクション区切り線
local SECTION_LINE = "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

---質問セクションをレンダリング
---@param question table Question object
---@param question_index number 質問番号（1-based）
---@param total_questions number 質問総数
---@return string[] lines レンダリングされた行
local function render_question(question, question_index, total_questions)
  local lines = {}

  -- ヘッダー
  table.insert(lines, "")
  table.insert(lines, SECTION_LINE)
  local multi_select_label = question.multiSelect and " (Multi-select)" or ""
  table.insert(
    lines,
    string.format("📋 Question %d/%d: %s%s", question_index, total_questions, question.header, multi_select_label)
  )
  table.insert(lines, SECTION_LINE)
  table.insert(lines, "")

  -- 質問文
  table.insert(lines, question.question)
  table.insert(lines, "")

  -- 操作説明
  table.insert(lines, "Delete unwanted options with dd, press <CR> to confirm, <Esc> to cancel")
  table.insert(lines, "")

  -- 選択肢（Concealed textでマーカーを埋め込む）
  for _, option in ipairs(question.options) do
    -- 選択肢のラベル行にマーカーを埋め込む
    local option_line = string.format("%s<!--vibing:option:%s-->", option.label, option.label)
    table.insert(lines, option_line)

    -- 説明行
    if option.description and option.description ~= "" then
      table.insert(lines, option.description)
    end
    table.insert(lines, "")
  end

  -- フッター
  table.insert(lines, SECTION_LINE)

  return lines
end

---回答セクションをレンダリング
---@param question table Question object
---@param answers string[] 選択された回答のラベル
---@return string[] lines レンダリングされた行
local function render_answer(question, answers)
  local lines = {}

  -- ヘッダー
  table.insert(lines, "")
  table.insert(lines, SECTION_LINE)
  local multi_select_label = question.multiSelect and " (Multi-select)" or ""
  table.insert(lines, string.format("📋 %s%s", question.header, multi_select_label))
  table.insert(lines, SECTION_LINE)
  table.insert(lines, "")

  -- 質問文
  table.insert(lines, question.question)
  table.insert(lines, "")

  -- 回答
  if #answers > 0 then
    local answer_str = table.concat(answers, ", ")
    table.insert(lines, string.format("✓ Selected: %s", answer_str))
  else
    table.insert(lines, "❌ No selection (cancelled)")
  end

  -- フッター
  table.insert(lines, SECTION_LINE)

  return lines
end

---バッファから残っている選択肢を収集
---@param buf number バッファ番号
---@param start_line number 検索開始行（0-based）
---@param end_line number 検索終了行（0-based、exclusive）
---@return string[] options 残っている選択肢のラベル
local function collect_remaining_options(buf, start_line, end_line)
  local lines = vim.api.nvim_buf_get_lines(buf, start_line, end_line, false)
  local options = {}

  for _, line in ipairs(lines) do
    local option = line:match(OPTION_MARKER_PATTERN)
    if option then
      table.insert(options, option)
    end
  end

  return options
end

---キーマップを設定
---@param buf number バッファ番号
local function setup_keymaps(buf)
  -- 元のキーマップを保存（復元用）
  state.original_keymaps = {}

  -- Enter: 確定
  vim.keymap.set("n", "<CR>", function()
    M.confirm()
  end, { buffer = buf, nowait = true, desc = "Confirm selection" })

  -- Escape: キャンセル
  vim.keymap.set("n", "<Esc>", function()
    M.cancel()
  end, { buffer = buf, nowait = true, desc = "Cancel question" })
end

---キーマップをクリーンアップ
---@param buf number バッファ番号
local function cleanup_keymaps(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end

  -- 設定したキーマップを削除
  pcall(vim.keymap.del, "n", "<CR>", { buffer = buf })
  pcall(vim.keymap.del, "n", "<Esc>", { buffer = buf })

  state.original_keymaps = nil
end

---質問セクションを回答セクションに置き換え
---@param buf number バッファ番号
---@param start_line number 開始行（0-based）
---@param end_line number 終了行（0-based、exclusive）
---@param question table Question object
---@param answers string[] 選択された回答
local function replace_with_answer(buf, start_line, end_line, question, answers)
  local answer_lines = render_answer(question, answers)
  vim.api.nvim_buf_set_lines(buf, start_line, end_line, false, answer_lines)
end

---質問を表示
---@param chat_buffer table ChatBuffer instance
---@param question table Question object from SDK
---@param question_index number 質問番号（1-based）
---@param total_questions number 質問総数
---@param callback function(answers: string[]?) 回答コールバック（nilはキャンセル）
function M.show(chat_buffer, question, question_index, total_questions, callback)
  if state.active then
    notify.warn("Another question is already active")
    callback(nil)
    return
  end

  local buf = chat_buffer:get_buffer()
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    notify.error("Invalid chat buffer")
    callback(nil)
    return
  end

  -- 質問セクションをレンダリング
  local question_lines = render_question(question, question_index, total_questions)

  -- バッファの末尾に追加
  local line_count = vim.api.nvim_buf_line_count(buf)
  local start_line = line_count
  vim.api.nvim_buf_set_lines(buf, start_line, start_line, false, question_lines)
  local end_line = start_line + #question_lines

  -- 状態を更新
  state.active = true
  state.buf = buf
  state.question_start_line = start_line
  state.question_end_line = end_line
  state.question = question
  state.callback = callback

  -- キーマップを設定
  setup_keymaps(buf)

  -- カーソルを質問セクションに移動
  if chat_buffer:is_open() then
    local win = chat_buffer.win
    if win and vim.api.nvim_win_is_valid(win) then
      -- 最初の選択肢の行に移動
      local cursor_line = start_line + 8 -- ヘッダー + 説明を飛ばした位置
      pcall(vim.api.nvim_win_set_cursor, win, { cursor_line, 0 })
    end
  end
end

---選択を確定
function M.confirm()
  if not state.active then
    return
  end

  local buf = state.buf
  local question = state.question
  local callback = state.callback
  local start_line = state.question_start_line
  local end_line = state.question_end_line

  -- 残っている選択肢を収集
  local answers = collect_remaining_options(buf, start_line, end_line)

  -- バリデーション
  if #answers == 0 then
    notify.warn("No options selected. Please keep at least one option.")
    return
  end

  -- 単一選択で複数残っている場合
  if not question.multiSelect and #answers > 1 then
    notify.warn(string.format("Please select only one option. Currently %d options remain.", #answers))
    return
  end

  -- 質問セクションを回答セクションに置き換え
  -- 現在の終了行を再計算（ユーザーが行を削除しているため）
  local current_end_line = vim.api.nvim_buf_line_count(buf)
  -- 質問セクションの実際の終了行を探す
  local actual_end_line = start_line
  local lines = vim.api.nvim_buf_get_lines(buf, start_line, current_end_line, false)
  for i, line in ipairs(lines) do
    if line == SECTION_LINE then
      actual_end_line = start_line + i
    end
  end

  replace_with_answer(buf, start_line, actual_end_line, question, answers)

  -- クリーンアップ
  cleanup_keymaps(buf)
  state.active = false
  state.buf = nil
  state.question_start_line = nil
  state.question_end_line = nil
  state.question = nil
  state.callback = nil

  -- コールバック実行
  if callback then
    callback(answers)
  end
end

---質問をキャンセル
function M.cancel()
  if not state.active then
    return
  end

  local buf = state.buf
  local question = state.question
  local callback = state.callback
  local start_line = state.question_start_line

  -- 質問セクションを「キャンセル済み」表示に置き換え
  local current_end_line = vim.api.nvim_buf_line_count(buf)
  local actual_end_line = start_line
  local lines = vim.api.nvim_buf_get_lines(buf, start_line, current_end_line, false)
  for i, line in ipairs(lines) do
    if line == SECTION_LINE then
      actual_end_line = start_line + i
    end
  end

  replace_with_answer(buf, start_line, actual_end_line, question, {})

  -- クリーンアップ
  cleanup_keymaps(buf)
  state.active = false
  state.buf = nil
  state.question_start_line = nil
  state.question_end_line = nil
  state.question = nil
  state.callback = nil

  -- コールバック実行（nilでキャンセルを通知）
  if callback then
    callback(nil)
  end
end

---質問が表示中かどうか
---@return boolean
function M.is_active()
  return state.active
end

---現在の質問のバッファを取得
---@return number?
function M.get_active_buffer()
  return state.buf
end

return M
