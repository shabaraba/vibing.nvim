---@class Vibing.Presentation
---プレゼンテーション層のエントリポイント
local M = {}

-- Common
M.Window = require("vibing.presentation.common.window")

-- Chat
M.Chat = require("vibing.presentation.chat")
M.ChatBuffer = require("vibing.presentation.chat.buffer")

return M
