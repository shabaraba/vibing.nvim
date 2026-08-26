---@class Vibing.Presentation.ChatController
---チャット機能のPresentation層Controller
---ユーザー入力を受け取り、Use Caseを呼び出し、Viewに結果を渡す責務を持つ
local M = {}

local notify = require("vibing.core.utils.notify")

---コマンド引数として受け付けるウィンドウ位置
---（MCPツール nvim_chat_create と同じ集合を使う。定義元は core/constants/chat.lua）
local ChatConstants = require("vibing.core.constants.chat")

---位置指定のみを取る引数をパースする（不正値は警告してデフォルトに落とす）
---@param args string?
---@return string? position
local function parse_position(args)
  if not args or args == "" then
    return nil
  end
  if ChatConstants.is_valid_position(args) then
    return args
  end
  notify.warn("Invalid position: " .. args .. ". Using default.")
  return nil
end

---チャットウィンドウを開く（新規または既存ファイル）
---@param args string 引数文字列（位置指定またはファイルパス）
function M.handle_open(args)
  local use_case = require("vibing.application.chat.use_case")
  local view = require("vibing.presentation.chat.view")

  -- 引数をパース（位置指定 or ファイルパス）
  local position = nil
  local file_path = nil

  if args and args ~= "" then
    if ChatConstants.is_valid_position(args) then
      position = args
    else
      -- 位置キーワードでなければファイルパスとして扱う
      file_path = args
    end
  end

  if file_path then
    -- 既存ファイルを開く
    local session = use_case.open_file(file_path)
    if session then
      view.render(session, position)
    else
      notify.error("Failed to load: " .. file_path, "Chat")
    end
  else
    -- 新規チャットを開く（位置指定あり/なし）
    local session = use_case.create_new()
    view.render(session, position)
  end
end

---チャットウィンドウをトグル
function M.handle_toggle()
  local use_case = require("vibing.application.chat.use_case")
  local view = require("vibing.presentation.chat.view")

  if view.is_open() then
    view.close()
  else
    local session = use_case.get_or_create_session()
    view.render(session)
  end
end

---スラッシュコマンドピッカーを表示
function M.show_slash_commands()
  require("vibing.ui.command_picker").show()
end

---チャットファイルにAIタイトルを設定
function M.handle_set_file_title()
  local view = require("vibing.presentation.chat.view")

  if not view.is_current_buffer_chat() then
    notify.warn("Not in a vibing chat buffer")
    return
  end

  local handler = require("vibing.application.chat.handlers.set_file_title")
  local current_view = view.get_current()
  handler({}, current_view)
end

---`:VibingSummarize` の引数をパースする（未知の引数は警告して要約自体は続行）
---@param args string?
---@return boolean with_title
local function parse_summarize_flags(args)
  local with_title = false
  for arg in (args or ""):gmatch("%S+") do
    if arg == "--with-title" then
      with_title = true
    else
      notify.warn("Unknown argument: " .. arg)
    end
  end
  return with_title
end

---チャット履歴からサマリーを生成してバッファに挿入
---@param args string? 引数文字列（`--with-title` で続けてタイトル生成まで行う）
function M.handle_summarize(args)
  local view = require("vibing.presentation.chat.view")
  local current_view = view.get_current()

  if not current_view then
    notify.warn("Not in a vibing chat buffer")
    return
  end

  local with_title = parse_summarize_flags(args)

  local use_case = require("vibing.application.chat.use_case")
  use_case.generate_and_insert_summary(current_view, {
    on_done = with_title and function(ok)
      -- 失敗時は通知済みなので追わない。summary が無いまま走らせるとタイトル生成は抜粋に
      -- フォールバックし、ユーザーが頼んでいない API 呼び出しが1回余分に走る。
      if not ok then
        return
      end
      -- `M.handle_set_file_title()` ではなくハンドラを直接呼び、最初に掴んだバッファを渡す。
      -- 要約は非同期なので、完了時点のカレントバッファは別のチャット（あるいは非チャット）に
      -- なっていることがある。
      require("vibing.application.chat.handlers.set_file_title")({}, current_view)
    end or nil,
  })
end

---チャットをフォーク
---@param args string? 引数文字列（位置指定のみ）
function M.handle_fork(args)
  local view = require("vibing.presentation.chat.view")
  local current_view = view.get_current()

  if not current_view then
    notify.error("Not in a vibing chat buffer")
    return
  end

  local position = parse_position(args)

  -- フォークセッションを作成
  local fork_use_case = require("vibing.application.chat.use_cases.fork")
  local fork_session = fork_use_case.execute(current_view)

  if fork_session then
    view.render(fork_session, position)
  else
    notify.error("Failed to fork chat session")
  end
end

---このチャットが起動したsubagentとの継続対話を開く
---@param args string? 引数文字列（位置指定のみ）
function M.handle_subagent_chat(args)
  local view = require("vibing.presentation.chat.view")
  local current_view = view.get_current()

  if not current_view then
    notify.error("Not in a vibing chat buffer")
    return
  end

  local finder = require("vibing.presentation.chat.modules.subagent_finder")
  local refs = finder.find_all(current_view.buf)

  if #refs == 0 then
    notify.error("No resumable subagent in this chat (built-in Explore/Plan agents cannot be resumed)")
    return
  end

  local position = parse_position(args)

  local function open(ref)
    local use_case = require("vibing.application.chat.use_cases.subagent_chat")
    local session, existing_path = use_case.execute(current_view, ref.agent_id)

    if existing_path then
      notify.info("Reopening the existing chat for this subagent")
      vim.cmd.edit(vim.fn.fnameescape(existing_path))
      return
    end
    if session then
      view.render(session, position)
    end
  end

  if #refs == 1 then
    open(refs[1])
    return
  end

  vim.ui.select(refs, {
    prompt = "Continue which subagent?",
    format_item = finder.describe,
  }, function(choice)
    if choice then
      open(choice)
    end
  end)
end

---現在のチャットバッファでUserセクションのヘッダー行番号を集める（1-indexed, 昇順）
---@param buf number バッファ番号
---@return number[] lines
function M._collect_user_header_lines(buf)
  local Timestamp = require("vibing.core.utils.timestamp")
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local result = {}
  for i, line in ipairs(lines) do
    if Timestamp.extract_role(line) == "user" then
      table.insert(result, i)
    end
  end
  return result
end

---カーソル行から数えてcount個目のUserヘッダー行を返す
---countが残り個数を超える場合は端のヘッダーを返す。`]`/`[` 系の慣習に合わせ、
---「行けるところまで行く」ほうが動かないより使いやすい。
---@param headers number[] Userヘッダーの行番号（1-indexed, 昇順）
---@param cur number 現在のカーソル行（1-indexed）
---@param direction "next"|"prev" 移動方向
---@param count number|nil 何個進むか（省略時は1）
---@return number|nil target 移動先の行番号。移動先が無ければnil
function M._resolve_jump_target(headers, cur, direction, count)
  -- Both "no count" spellings arrive here: nil from a direct Lua call, and 0 from
  -- nvim_create_user_command{ count = 0 } when the user typed none. Neither means "stay put".
  count = math.max(count or 1, 1)

  local candidates = {}
  if direction == "next" then
    for _, lnum in ipairs(headers) do
      if lnum > cur then
        table.insert(candidates, lnum)
      end
    end
  else
    for i = #headers, 1, -1 do
      if headers[i] < cur then
        table.insert(candidates, headers[i])
      end
    end
  end

  if #candidates == 0 then
    return nil
  end
  return candidates[math.min(count, #candidates)]
end

---次/前のUserセクションへカーソルを移動
---コマンド `:VibingChatJumpNextUser` / `:VibingChatJumpPrevUser` から呼ばれる
---@param direction "next"|"prev" 移動方向
---@param count number|nil いくつ先のセクションへ飛ぶか（省略時は1）
function M.handle_jump_user(direction, count)
  if direction ~= "next" and direction ~= "prev" then
    notify.warn(string.format("Unknown jump direction: %s", tostring(direction)))
    return
  end

  local view = require("vibing.presentation.chat.view")
  local current_view = view.get_current()

  if not current_view then
    notify.warn("Not in a vibing chat buffer")
    return
  end

  local headers = M._collect_user_header_lines(current_view.buf)
  if #headers == 0 then
    notify.info("No User section found")
    return
  end

  local cur = vim.api.nvim_win_get_cursor(0)[1] -- 1-indexed
  local target = M._resolve_jump_target(headers, cur, direction, count)

  if not target then
    notify.info(direction == "next" and "No next User section" or "No previous User section")
    return
  end

  -- nvim_win_set_cursor は ' マークも jumplist も更新しないので明示的に積む。
  -- これが無いと、このコマンドに ]u などを割り当てたとき <C-o> で戻れず、
  -- 他の `]`/`[` 系モーションと挙動が食い違う。
  vim.cmd("normal! m'")
  -- pcall to match every other nvim_win_set_cursor call site in the codebase (buffer.lua,
  -- renderer.lua, oil.lua). `target` came from this same buffer a moment ago, but a cursor move
  -- is not worth an error dialog if the buffer changed underneath us.
  pcall(vim.api.nvim_win_set_cursor, 0, { target, 0 })
  vim.cmd("normal! zz")
end

return M
