---@class Vibing.Application
local M = {}

-- Chat
M.ChatInit = require("vibing.application.chat")
M.ChatCommands = require("vibing.application.chat.commands")
M.ChatCustomCommands = require("vibing.application.chat.custom_commands")
M.ChatCompletion = require("vibing.application.chat.completion")
M.SendMessageUseCase = require("vibing.application.chat.send_message")

-- Context
M.ContextManager = require("vibing.application.context.manager")

-- Commands
M.CommandHandler = require("vibing.application.commands.handler")

return M
