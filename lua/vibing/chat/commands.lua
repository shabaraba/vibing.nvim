local notify = require("vibing.utils.notify")

---@class Vibing.SlashCommand
---チャット内で使用可能なスラッシュコマンドの定義
---@field name string コマンド名（/の後に入力する文字列、例: "context", "clear"）
---@field handler fun(args: string[], chat_buffer: Vibing.ChatBuffer): boolean ハンドラー関数（引数とバッファを受け取り成功/失敗を返す）
---@field description string コマンドの説明文（/helpで表示される）

---@class Vibing.CommandRegistry
---チャットコマンドレジストリ
---スラッシュコマンドの登録、パース、実行を管理
local M = {}

---登録済みコマンドのマップ（コマンド名 → SlashCommandオブジェクト）
---@type table<string, Vibing.SlashCommand>
M.commands = {}

---登録済みカスタムコマンドのマップ（コマンド名 → SlashCommandオブジェクト）
---@type table<string, Vibing.SlashCommand>
M.custom_commands = {}

---新しいスラッシュコマンドを登録
---chat/init.luaから組み込みコマンドの登録に使用される
---同名のコマンドが既に存在する場合は上書き
---@param command Vibing.SlashCommand 登録するコマンド（name, handler, description）
function M.register(command)
  M.commands[command.name] = command
end

---メッセージがスラッシュコマンドかどうかを判定
---先頭が/で始まり、その後に単語文字（\w+）が続く場合にtrueを返す
---@param message string チェックするメッセージ文字列
---@return boolean メッセージがスラッシュコマンドの形式ならtrue
function M.is_command(message)
  return message:match("^/%w+") ~= nil
end

---メッセージからコマンド名と引数を抽出
---例: "/context foo.lua" → ("context", {"foo.lua"})
---先頭の/を削除してスペースで分割し、最初の要素をコマンド名、残りを引数とする
---@param message string パースするメッセージ文字列
---@return string? command_name コマンド名（コマンドでない場合はnil）
---@return string[] args コマンド引数の配列（空配列の場合あり）
function M.parse(message)
  -- 先頭の/を削除してスペースで分割
  local trimmed = vim.trim(message)
  if not trimmed:match("^/") then
    return nil, {}
  end

  -- /commandとそれ以降を分離
  local parts = vim.split(trimmed:sub(2), "%s+", { trimempty = true })
  if #parts == 0 then
    return nil, {}
  end

  local command_name = parts[1]
  local args = {}
  for i = 2, #parts do
    table.insert(args, parts[i])
  end

  return command_name, args
end

---スラッシュコマンドを実行
---メッセージをパースし、登録済みハンドラーを呼び出す
---未登録のコマンドの場合は警告を表示
---ハンドラー実行中のエラーはpcallでキャッチして通知
---@param message string 実行するコマンド文字列（例: "/context foo.lua"）
---@param chat_buffer Vibing.ChatBuffer コマンドを実行するチャットバッファ
---@return boolean handled コマンドとして処理された場合true（成功/失敗問わず）、コマンド形式でない場合false
---@return boolean is_custom カスタムコマンドの場合true、ビルトインの場合false
function M.execute(message, chat_buffer)
  local command_name, args = M.parse(message)

  if not command_name then
    return false, false
  end

  -- 組み込みコマンドを確認
  local command = M.commands[command_name]
  local is_custom = false

  -- カスタムコマンドも確認
  if not command then
    command = M.custom_commands[command_name]
    is_custom = command ~= nil
  end

  if not command then
    -- 未知のコマンドはAgent SDKにフォールバック（プラグインマーケットのコマンド用）
    return false, false -- 処理されなかったのでAgent SDKに渡す
  end

  -- コマンドハンドラーを実行
  local success, result = pcall(command.handler, args, chat_buffer)
  if not success then
    notify.error(string.format("Command error: %s", result))
  end

  return true, is_custom
end

---登録済みコマンドの一覧を取得
---コマンド名でソート済みの配列を返す
---/helpコマンドでの一覧表示に使用
---@return Vibing.SlashCommand[] コマンド名でソートされたコマンドオブジェクトの配列
function M.list()
  local list = {}
  for _, command in pairs(M.commands) do
    table.insert(list, command)
  end
  table.sort(list, function(a, b) return a.name < b.name end)
  return list
end

---コマンド内容が引数プレースホルダーを含むかチェック
---@param content string コマンド内容
---@return boolean プレースホルダーを含む場合true
local function has_argument_placeholders(content)
  return content:match("%$ARGUMENTS") ~= nil
    or content:match("{{ARGUMENTS}}") ~= nil
    or content:match("{{%d+}}") ~= nil
end

---カスタムコマンドを実行
---@param custom_cmd Vibing.CustomCommand カスタムコマンド情報
---@param args string[] コマンド引数
---@param chat_buffer Vibing.ChatBuffer チャットバッファ
local function execute_custom_command(custom_cmd, args, chat_buffer)
  local message = custom_cmd.content

  -- 全引数を結合
  local all_args = table.concat(args, " ")

  -- プレースホルダー置換
  -- $ARGUMENTS と {{ARGUMENTS}} を全引数に置換
  -- 関数形式を使用して%などの特殊文字をエスケープ
  message = message:gsub("%$ARGUMENTS", function() return all_args end)
  message = message:gsub("{{ARGUMENTS}}", function() return all_args end)

  -- 個別引数の置換（例: {{1}}, {{2}}）
  -- 関数形式を使用してargの特殊文字（%など）をエスケープ
  for i, arg in ipairs(args) do
    message = message:gsub("{{" .. i .. "}}", function() return arg end)
  end

  -- チャットバッファの確認
  if not chat_buffer then
    notify.error("No chat buffer")
    return false
  end

  -- プロンプトが空でないか確認
  if vim.trim(message) == "" then
    notify.error(string.format("Custom command /%s produced empty prompt", custom_cmd.name))
    return false
  end

  -- Agentに直接送信（バッファに展開しない）
  -- Note: M.send()が最後にadd_user_section()を呼ぶため、ここでは呼ばない
  vim.schedule(function()
    require("vibing.actions.chat").send(chat_buffer, message)
  end)

  notify.info(string.format("Custom command executed: /%s", custom_cmd.name))
  return true
end

---カスタムコマンドを登録
---Markdown内容をチャットバッファに挿入するハンドラーを自動生成
---引数が必要なコマンドで引数がない場合は入力プロンプトを表示
---@param custom_cmd Vibing.CustomCommand カスタムコマンド情報
function M.register_custom(custom_cmd)
  local requires_args = has_argument_placeholders(custom_cmd.content)

  M.custom_commands[custom_cmd.name] = {
    name = custom_cmd.name,
    handler = function(args, chat_buffer)
      -- 引数が必要だが提供されていない場合、入力を促す
      if requires_args and #args == 0 then
        vim.ui.input({
          prompt = string.format("/%s argument: ", custom_cmd.name),
        }, function(input)
          if input and vim.trim(input) ~= "" then
            -- 入力を引数として使用
            local input_args = vim.split(input, "%s+", { trimempty = true })
            execute_custom_command(custom_cmd, input_args, chat_buffer)
          else
            notify.warn(string.format("/%s requires an argument", custom_cmd.name))
          end
        end)
        return true
      end

      return execute_custom_command(custom_cmd, args, chat_buffer)
    end,
    description = custom_cmd.description,
    source = custom_cmd.source,
    requires_args = requires_args,
  }
end

---全コマンドを取得（組み込み + カスタム）
---補完やピッカーで使用
---@return table<string, Vibing.SlashCommand> コマンド名をキーとするマップ
function M.list_all()
  local all = {}

  -- 組み込みコマンド
  for name, cmd in pairs(M.commands) do
    all[name] = vim.tbl_extend("force", cmd, { source = "builtin" })
  end

  -- カスタムコマンド
  for name, cmd in pairs(M.custom_commands) do
    all[name] = cmd
  end

  return all
end

---コマンド引数の補完候補を取得
---mode, modelコマンドの引数補完に使用
---@param command_name string コマンド名
---@return string[]? 補完候補（nilの場合は補完なし）
function M.get_argument_completions(command_name)
  local completions = {
    mode = { "auto", "plan", "code", "explore" },
    model = { "opus", "sonnet", "haiku" },
  }
  return completions[command_name]
end

return M
