---@class Vibing.Application
---アプリケーション層のエントリポイント
local M = {}

-- Chat
M.SendMessageUseCase = require("vibing.application.chat.send_message")

-- Context
M.ContextManager = require("vibing.application.context.manager")

-- Inline
M.InlineExecutor = require("vibing.application.inline.executor")
M.QueueManager = require("vibing.application.inline.queue_manager")

-- Commands
M.CommandHandler = require("vibing.application.commands.handler")

return M
