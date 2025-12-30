---@class Vibing.Domain
---ドメイン層のエントリポイント
local M = {}

-- Entities
M.Session = require("vibing.domain.session.entity")
M.Context = require("vibing.domain.context.entity")
M.Conversation = require("vibing.domain.conversation.entity")
M.Message = require("vibing.domain.chat.message")
M.InlineTask = require("vibing.domain.inline.entity")
M.PermissionRule = require("vibing.domain.permissions.rule")
M.PermissionEvaluator = require("vibing.domain.permissions.evaluator")

return M
