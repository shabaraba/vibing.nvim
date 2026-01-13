---@class Vibing.ChatInit
local M = {}

function M.setup()
  local commands = require("vibing.application.chat.commands")

  commands.register({
    name = "context",
    handler = require("vibing.application.chat.handlers.context"),
    description = "Add file to context: /context <file_path>",
  })

  commands.register({
    name = "clear",
    handler = require("vibing.application.chat.handlers.clear"),
    description = "Clear context",
  })

  commands.register({
    name = "save",
    handler = require("vibing.application.chat.handlers.save"),
    description = "Save current chat",
  })

  commands.register({
    name = "summarize",
    handler = require("vibing.application.chat.handlers.summarize"),
    description = "Summarize conversation",
  })

  commands.register({
    name = "mode",
    handler = require("vibing.application.chat.handlers.mode"),
    description = "Set execution mode: /mode <auto|plan|code>",
  })

  commands.register({
    name = "model",
    handler = require("vibing.application.chat.handlers.model"),
    description = "Set AI model: /model <opus|sonnet|haiku>",
  })

  commands.register({
    name = "help",
    handler = require("vibing.application.chat.handlers.help"),
    description = "Show available slash commands",
  })

  commands.register({
    name = "allow",
    handler = require("vibing.application.chat.handlers.allow"),
    description = "Allow tool: /allow <tool>, /allow Tool(pattern), or /allow -<tool> to remove",
  })

  commands.register({
    name = "deny",
    handler = require("vibing.application.chat.handlers.deny"),
    description = "Deny tool: /deny <tool> or /deny -<tool> to remove",
  })

  commands.register({
    name = "ask",
    handler = require("vibing.application.chat.handlers.ask"),
    description = "Ask before using tool: /ask <tool> or /ask -<tool> to remove",
  })

  commands.register({
    name = "permission",
    handler = require("vibing.application.chat.handlers.permission"),
    description = "Set permission mode: /permission <default|acceptEdits|bypassPermissions>",
  })

  commands.register({
    name = "permissions",
    handler = require("vibing.application.chat.handlers.permissions"),
    description = "Build and add permission rules: /permissions or /perm",
  })

  commands.register({
    name = "perm",
    handler = require("vibing.application.chat.handlers.permissions"),
    description = "Alias for /permissions",
  })

  commands.register({
    name = "new-session",
    handler = require("vibing.application.chat.handlers.new_session"),
    description = "Reset session and start fresh: /new-session",
  })
end

return M
