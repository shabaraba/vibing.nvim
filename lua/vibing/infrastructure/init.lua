---@class Vibing.Infrastructure
---インフラストラクチャ層のエントリポイント
local M = {}

-- Adapters
M.BaseAdapter = require("vibing.infrastructure.adapter.base")
M.AgentSDKAdapter = require("vibing.infrastructure.adapter.agent_sdk")

-- RPC
M.RpcServer = require("vibing.infrastructure.rpc.server")

-- Nvim Integration
M.CommandValidator = require("vibing.infrastructure.nvim.command_validator")
M.BufferManager = require("vibing.infrastructure.buffer.manager")

-- Storage
M.Frontmatter = require("vibing.infrastructure.storage.frontmatter")
M.FileReader = require("vibing.infrastructure.file.reader")
M.FileWriter = require("vibing.infrastructure.file.writer")

return M
