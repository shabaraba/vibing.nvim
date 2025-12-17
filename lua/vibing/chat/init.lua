---Chat module initializer
local M = {}

---Initialize chat commands
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
end

return M
