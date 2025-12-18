---@class Vibing.ChatInit
---チャットシステムの初期化モジュール
---組み込みチャットコマンド（/context, /clear, /save, /summarize, /mode, /model, /allow, /deny）を登録
local M = {}

---チャットコマンドシステムを初期化
---プラグイン起動時に呼び出され、組み込みコマンドをcommands.registerで登録
---各コマンドはchat/handlers/配下のハンドラー関数と紐付けられる
---登録後は/helpでコマンド一覧が表示可能になる
function M.setup()
  local commands = require("vibing.chat.commands")

  -- Register built-in commands
  commands.register({
    name = "context",
    handler = require("vibing.chat.handlers.context"),
    description = "Add file to context: /context <file_path>",
  })

  commands.register({
    name = "clear",
    handler = require("vibing.chat.handlers.clear"),
    description = "Clear context",
  })

  commands.register({
    name = "save",
    handler = require("vibing.chat.handlers.save"),
    description = "Save current chat",
  })

  commands.register({
    name = "summarize",
    handler = require("vibing.chat.handlers.summarize"),
    description = "Summarize conversation",
  })

  commands.register({
    name = "mode",
    handler = require("vibing.chat.handlers.mode"),
    description = "Set execution mode: /mode <auto|plan|code>",
  })

  commands.register({
    name = "model",
    handler = require("vibing.chat.handlers.model"),
    description = "Set AI model: /model <opus|sonnet|haiku>",
  })

  commands.register({
    name = "help",
    handler = require("vibing.chat.handlers.help"),
    description = "Show available slash commands",
  })

  commands.register({
    name = "allow",
    handler = require("vibing.chat.handlers.allow"),
    description = "Allow tool: /allow <tool> or /allow -<tool> to remove",
  })

  commands.register({
    name = "deny",
    handler = require("vibing.chat.handlers.deny"),
    description = "Deny tool: /deny <tool> or /deny -<tool> to remove",
  })

  commands.register({
    name = "permission",
    handler = require("vibing.chat.handlers.permission"),
    description = "Set permission mode: /permission <default|acceptEdits|bypassPermissions>",
  })
end

return M
