---@class Vibing.Presentation.ContextController
---コンテキスト管理のPresentation層Controller
---ユーザー入力を受け取り、Application層を呼び出す責務を持つ
local M = {}

---コンテキストにファイルまたは選択範囲を追加
---@param opts table Neovimコマンドのオプション（args, range等）
function M.handle_add(opts)
  local Context = require("vibing.application.context.manager")
  local notify = require("vibing.core.utils.notify")

  -- 優先順位1: oil.nvimバッファからファイルを追加（範囲選択より優先）
  local ok, oil = pcall(require, "vibing.integrations.oil")
  if ok and oil.is_oil_buffer() then
    -- 範囲選択がある場合は複数ファイルを取得
    local start_line, end_line
    if opts.range > 0 then
      start_line = opts.line1
      end_line = opts.line2
    end

    local files = oil.get_selected_files(start_line, end_line)
    if #files > 0 then
      -- 複数ファイルをコンテキストに追加
      for _, file_path in ipairs(files) do
        Context.add(file_path)
      end
      M._update_chat_context_if_open()

      -- 複数ファイルの場合はまとめてクリップボードにコピー
      if #files > 1 then
        local all_contexts = vim.tbl_map(function(path)
          return require("vibing.infrastructure.context.collector").file_to_context(path)
        end, files)
        local clipboard_content = table.concat(all_contexts, "\n")
        if vim.fn.has("clipboard") == 1 then
          vim.fn.setreg("+", clipboard_content)
        else
          vim.fn.setreg('"', clipboard_content)
        end
        notify.info(string.format("Added %d files to context (copied to clipboard)", #files), "Context")
      end
      return
    end
    -- ファイルが取得できない場合（ディレクトリ等）は警告を表示
    notify.warn("No file selected (directories are not supported)", "Context")
    return
  end

  -- 優先順位2: 範囲選択（存在する場合）
  if opts.range > 0 then
    Context.add_selection()
    M._update_chat_context_if_open()
    return
  end

  -- 優先順位3: ファイルパス引数
  if opts.args ~= "" then
    Context.add(opts.args)
    M._update_chat_context_if_open()
    return
  end

  -- 優先順位4: 現在のバッファ
  Context.add()
  M._update_chat_context_if_open()
end

---コンテキストをクリア
function M.handle_clear()
  local Context = require("vibing.application.context.manager")
  Context.clear()
  M._update_chat_context_if_open()
end

---@private
---チャットバッファが開いている場合、コンテキスト行を更新
function M._update_chat_context_if_open()
  local view = require("vibing.presentation.chat.view")
  if view.is_open() then
    local current_view = view.get_current()
    if current_view and current_view.buf then
      local Renderer = require("vibing.presentation.chat.modules.renderer")
      Renderer.updateContextLine(current_view.buf)
    end
  end
end

return M
