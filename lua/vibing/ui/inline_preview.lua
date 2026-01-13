local git = require("vibing.core.utils.git")
local BufferReload = require("vibing.core.utils.buffer_reload")
local BufferIdentifier = require("vibing.core.utils.buffer_identifier")
local Timestamp = require("vibing.core.utils.timestamp")
local State = require("vibing.ui.inline_preview.state")
local Layout = require("vibing.ui.inline_preview.layout")
local Renderer = require("vibing.ui.inline_preview.renderer")
local Handlers = require("vibing.ui.inline_preview.handlers")
local Keymaps = require("vibing.ui.inline_preview.keymaps")

---@class Vibing.InlinePreview
---インラインアクションとチャットのプレビューUI
---inlineモード: 3パネル構成（Files, Diff, Response）
---chatモード: 2パネル構成（Files, Diff）
local M = {}

---プレビューUIをセットアップして表示
---@param mode "inline"|"chat" 表示モード
---@param modified_files string[] 変更されたファイル一覧
---@param response_text string Agent SDKの応答テキスト（chatモードでは空文字列）
---@param saved_contents table<string, string[]>? Claude変更前のファイル内容（オプション）
---@param initial_file string? 初期選択するファイルパス（オプション）
---@param user_prompt string? ユーザーが入力したプロンプト（オプション）
---@param action string? 実行されたアクション名（オプション）
---@param instruction string? 追加指示（オプション）
---@param session_id string? セッションID（オプション）
---@return boolean success 成功した場合true
function M.setup(mode, modified_files, response_text, saved_contents, initial_file, user_prompt, action, instruction, session_id)
  if not git.is_git_repo() then
    vim.notify(
      "Preview mode requires a Git repository. This project is not under Git version control.",
      vim.log.levels.ERROR
    )
    return false
  end

  State.init({
    mode = mode,
    modified_files = modified_files,
    response_text = response_text,
    saved_contents = saved_contents,
    user_prompt = user_prompt,
    action = action,
    instruction = instruction,
    session_id = session_id,
    initial_idx = M._calculate_initial_idx(modified_files, initial_file),
  })

  local state = State.data

  local has_files = modified_files and #modified_files > 0
  local has_response = response_text and response_text ~= ""

  if mode == "inline" then
    if not has_files and not has_response then
      vim.notify(
        "No files were modified and no response available. Nothing to preview.",
        vim.log.levels.INFO
      )
      return false
    end
  else
    if not has_files then
      vim.notify(
        "No files were modified during this action. Nothing to preview.",
        vim.log.levels.INFO
      )
      return false
    end
  end

  if has_files then
    state.diffs = {}
    for _, file in ipairs(modified_files) do
      state.diffs[file] = M._generate_diff_from_saved(file)
    end
  else
    state.diffs = {}
  end

  local has_valid_diff = false
  for _, diff_data in pairs(state.diffs) do
    if not diff_data.error then
      has_valid_diff = true
      break
    end
  end

  if not has_valid_diff then
    vim.notify(
      "Failed to retrieve diffs for all modified files. Check Git status.",
      vim.log.levels.WARN
    )
  end

  Layout.create(state)
  Renderer.render_all(state)
  M._setup_keymaps(state)

  return true
end

---初期選択ファイルインデックスを計算
---@param modified_files string[]
---@param initial_file string?
---@return number
function M._calculate_initial_idx(modified_files, initial_file)
  if not initial_file or not modified_files or #modified_files == 0 then
    return 1
  end

  local normalized_initial = vim.fn.fnamemodify(initial_file, ":p")
  for i, file in ipairs(modified_files) do
    local normalized_file = vim.fn.fnamemodify(file, ":p")
    if normalized_file == normalized_initial then
      return i
    end
  end

  return 1
end

---一時ファイルを使ってgit diff --no-indexを実行
---@param before_lines string[] 変更前の行
---@param after_lines string[] 変更後の行
---@param file_path string ファイルパス（エラーメッセージ用）
---@return table { lines: string[], has_delta: boolean, error: boolean? }
local function _generate_diff_with_temp_files(before_lines, after_lines, file_path)
  local tmp_before = vim.fn.tempname()
  local tmp_after = vim.fn.tempname()

  local ok, result = pcall(function()
    vim.fn.writefile(before_lines, tmp_before)
    vim.fn.writefile(after_lines, tmp_after)

    local cmd = string.format(
      "git diff --no-index --no-color %s %s",
      vim.fn.shellescape(tmp_before),
      vim.fn.shellescape(tmp_after)
    )

    local lines = vim.fn.systemlist({ "sh", "-c", cmd })

    if vim.v.shell_error ~= 0 and vim.v.shell_error ~= 1 then
      error(string.format("git diff failed with exit code %d", vim.v.shell_error))
    end

    return lines
  end)

  vim.fn.delete(tmp_before)
  vim.fn.delete(tmp_after)

  if not ok then
    return {
      lines = {
        "Error: Could not generate diff for " .. file_path,
        "Details: " .. tostring(result),
      },
      has_delta = false,
      error = true,
    }
  end

  if #result == 0 then
    return {
      lines = { "No changes detected for " .. file_path },
      has_delta = false,
      error = false,
    }
  end

  return {
    lines = result,
    has_delta = false,
    error = false,
  }
end

---保存された内容とファイルの差分を生成（git diff --no-index使用）
---@param file_path string ファイルパス
---@return table { lines: string[], has_delta: boolean, error: boolean? }
function M._generate_diff_from_saved(file_path)
  local state = State.data
  local is_buffer_id = BufferIdentifier.is_buffer_identifier(file_path)
  local normalized_path = BufferIdentifier.normalize_path(file_path)

  local file_exists = not is_buffer_id and vim.fn.filereadable(normalized_path) == 1

  if not file_exists then
    local bufnr
    if is_buffer_id then
      bufnr = BufferIdentifier.extract_bufnr(file_path)
    else
      bufnr = vim.fn.bufnr(normalized_path)
    end

    if not bufnr or bufnr == -1 or not vim.api.nvim_buf_is_loaded(bufnr) then
      return {
        lines = {
          "Error: Buffer not found or not loaded for " .. file_path,
        },
        has_delta = false,
        error = true,
      }
    end

    local ok, current_lines = pcall(vim.api.nvim_buf_get_lines, bufnr, 0, -1, false)
    if not ok then
      return {
        lines = {
          "Error: Failed to read buffer " .. file_path .. ": " .. tostring(current_lines),
        },
        has_delta = false,
        error = true,
      }
    end

    if state.saved_contents[normalized_path] then
      return _generate_diff_with_temp_files(state.saved_contents[normalized_path], current_lines, file_path)
    else
      local diff_lines = {
        "diff --git a/" .. file_path .. " b/" .. file_path,
        "new file",
        "--- /dev/null",
        "+++ b/" .. file_path,
        "@@ -0,0 +1," .. #current_lines .. " @@",
      }

      for _, line in ipairs(current_lines) do
        table.insert(diff_lines, "+" .. line)
      end

      return {
        lines = diff_lines,
        has_delta = #current_lines > 0,
        error = false,
      }
    end
  end

  local current_lines = vim.fn.readfile(file_path)

  if not state.saved_contents[normalized_path] then
    local cmd = string.format("git status --porcelain -- %s", vim.fn.shellescape(file_path))
    local status_output = vim.fn.system(cmd)
    local is_new_file = false
    for line in status_output:gmatch("[^\r\n]+") do
      if vim.startswith(line, "??") or vim.startswith(line, "A ") then
        is_new_file = true
        break
      end
    end

    if is_new_file then
      local diff_lines = {
        "diff --git a/" .. file_path .. " b/" .. file_path,
        "new file",
        "--- /dev/null",
        "+++ b/" .. file_path,
        "@@ -0,0 +1," .. #current_lines .. " @@",
      }

      for _, line in ipairs(current_lines) do
        table.insert(diff_lines, "+" .. line)
      end

      return {
        lines = diff_lines,
        has_delta = #current_lines > 0,
        error = false,
      }
    else
      return git.get_diff(file_path)
    end
  end

  return _generate_diff_with_temp_files(state.saved_contents[normalized_path], current_lines, file_path)
end

---キーマップを設定
---@param state Vibing.InlinePreview.State
function M._setup_keymaps(state)
  local function close_callback()
    M._close_all()
  end

  local handlers = {
    on_file_select_from_cursor = function()
      Handlers.on_file_select_from_cursor(state)
    end,
    on_accept = function()
      Handlers.on_accept(state, close_callback)
    end,
    on_reject = function()
      M._on_reject()
    end,
    on_quit = function()
      Handlers.on_quit(close_callback)
    end,
    save_as_vibing = function()
      M.save_as_vibing()
    end,
    cycle_window = function(direction)
      Handlers.cycle_window(state, direction)
    end,
    switch_panel = function(target_panel)
      Handlers.switch_panel(state, target_panel)
    end,
  }

  Keymaps.setup(state, handlers)
end

---Reject処理（変更を元に戻す）
function M._on_reject()
  local state = State.data

  if #state.modified_files == 0 then
    M._close_all()
    vim.notify("No files to revert", vim.log.levels.INFO)
    return
  end

  local files_with_saved = {}
  local files_without_saved = {}

  for _, file in ipairs(state.modified_files) do
    local is_buffer_id = file:match("^%[Buffer %d+%]$")
    local normalized_path

    if is_buffer_id then
      normalized_path = file
    else
      normalized_path = vim.fn.fnamemodify(file, ":p")
    end

    if state.saved_contents[normalized_path] then
      table.insert(files_with_saved, file)
    else
      table.insert(files_without_saved, file)
    end
  end

  local reverted_files = {}
  local errors = {}

  for _, file in ipairs(files_with_saved) do
    local is_buffer_id = file:match("^%[Buffer %d+%]$")
    local normalized_path

    if is_buffer_id then
      normalized_path = file
    else
      normalized_path = vim.fn.fnamemodify(file, ":p")
    end

    local ok, err = pcall(function()
      if is_buffer_id then
        local bufnr = tonumber(file:match("%[Buffer (%d+)%]"))
        if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
          vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, state.saved_contents[normalized_path])
        else
          error("Invalid buffer: " .. file)
        end
      else
        vim.fn.writefile(state.saved_contents[normalized_path], file)
      end
    end)

    if ok then
      table.insert(reverted_files, file)
    else
      table.insert(errors, { file = file, message = tostring(err) })
    end
  end

  if #files_without_saved > 0 then
    local git_files = {}
    for _, file in ipairs(files_without_saved) do
      local is_buffer_id = file:match("^%[Buffer %d+%]$")
      if not is_buffer_id then
        table.insert(git_files, file)
      else
        table.insert(errors, { file = file, message = "No saved content for unnamed buffer" })
      end
    end

    if #git_files > 0 then
      local result = git.checkout_files(git_files)

      if result.success then
        for _, file in ipairs(git_files) do
          table.insert(reverted_files, file)
        end
      else
        for _, err in ipairs(result.errors) do
          table.insert(errors, err)
        end
        for _, file in ipairs(git_files) do
          local found_error = false
          for _, err in ipairs(result.errors) do
            if err.file == file then
              found_error = true
              break
            end
          end
          if not found_error then
            table.insert(reverted_files, file)
          end
        end
      end
    end
  end

  if #errors == 0 then
    vim.notify(
      string.format("Reverted %d files successfully", #reverted_files),
      vim.log.levels.INFO
    )
  else
    local success_count = #reverted_files
    local failed_count = #errors

    vim.notify(
      string.format("Reverted %d/%d files. %d failed.", success_count, #state.modified_files, failed_count),
      vim.log.levels.WARN
    )

    for _, err in ipairs(errors) do
      vim.notify(string.format("  - %s: %s", err.file, err.message), vim.log.levels.ERROR)
    end
  end

  if #reverted_files > 0 then
    BufferReload.reload_files(reverted_files)
  end

  M._close_all()
end

---全UIを破棄
function M._close_all()
  local state = State.data

  for _, win in ipairs({ state.win_files, state.win_diff, state.win_response }) do
    if win and vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end

  for _, buf in ipairs({ state.buf_files, state.buf_diff, state.buf_response }) do
    if buf and vim.api.nvim_buf_is_valid(buf) then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end

  State.reset()
end

---現在のプレビュー内容を.vibingファイルとして保存してChatBufferで開く
---inlineモードでのみ使用可能（user_prompt, response_textが必要）
---@return boolean success 成功した場合true
function M.save_as_vibing()
  local state = State.data

  if state.mode ~= "inline" then
    vim.notify("Save as vibing is only available in inline mode", vim.log.levels.WARN)
    return false
  end

  if not state.user_prompt or state.user_prompt == "" then
    vim.notify("No user prompt available to save", vim.log.levels.WARN)
    return false
  end

  local project_root = vim.fn.getcwd()
  local save_dir = project_root .. "/.vibing/inline/"
  vim.fn.mkdir(save_dir, "p")

  local filename = os.date("inline-%Y%m%d-%H%M%S.vibing")
  local file_path = save_dir .. filename

  local lines = {}

  local vibing = require("vibing")
  local config = vibing.get_config()

  table.insert(lines, "---")
  table.insert(lines, "vibing.nvim: true")
  if state.session_id and state.session_id ~= "" then
    table.insert(lines, "session_id: " .. state.session_id)
  else
    table.insert(lines, "session_id: ~")
  end
  table.insert(lines, "created_at: " .. os.date("%Y-%m-%dT%H:%M:%S"))
  table.insert(lines, "source: inline")

  if state.action then
    table.insert(lines, "action: " .. state.action)
  end
  if state.instruction and state.instruction ~= "" then
    table.insert(lines, "instruction: " .. state.instruction)
  end

  if config.agent then
    if config.agent.default_mode then
      table.insert(lines, "mode: " .. config.agent.default_mode)
    end
    if config.agent.default_model then
      table.insert(lines, "model: " .. config.agent.default_model)
    end
  end

  if config.permissions then
    if config.permissions.mode then
      table.insert(lines, "permission_mode: " .. config.permissions.mode)
    end
    if config.permissions.allow and #config.permissions.allow > 0 then
      table.insert(lines, "permissions_allow:")
      for _, tool in ipairs(config.permissions.allow) do
        table.insert(lines, "  - " .. tool)
      end
    end
    if config.permissions.deny and #config.permissions.deny > 0 then
      table.insert(lines, "permissions_deny:")
      for _, tool in ipairs(config.permissions.deny) do
        table.insert(lines, "  - " .. tool)
      end
    end
  end

  table.insert(lines, "---")
  table.insert(lines, "")

  table.insert(lines, "# Inline Action Result")
  table.insert(lines, "")
  table.insert(lines, "---")
  table.insert(lines, "")

  table.insert(lines, Timestamp.create_header("User"))
  table.insert(lines, "")
  if state.user_prompt and state.user_prompt ~= "" then
    for _, line in ipairs(vim.split(state.user_prompt, "\n", { plain = true })) do
      table.insert(lines, line)
    end
  end
  table.insert(lines, "")

  table.insert(lines, Timestamp.create_header("Assistant"))
  table.insert(lines, "")
  if state.response_text and state.response_text ~= "" then
    for _, line in ipairs(vim.split(state.response_text, "\n", { plain = true })) do
      table.insert(lines, line)
    end
  else
    table.insert(lines, "(No response)")
  end
  table.insert(lines, "")

  if #state.modified_files > 0 then
    table.insert(lines, "### Modified Files")
    table.insert(lines, "")
    for _, file in ipairs(state.modified_files) do
      local relative = vim.fn.fnamemodify(file, ":.")
      table.insert(lines, relative)
    end
    table.insert(lines, "")
  end

  table.insert(lines, Timestamp.create_header("User"))
  table.insert(lines, "")

  vim.fn.writefile(lines, file_path)

  local ChatAction = require("vibing.application.chat.use_case")
  ChatAction.open_file(file_path)

  vim.notify("Saved as " .. filename, vim.log.levels.INFO)

  M._close_all()

  return true
end

return M
