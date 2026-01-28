---@class Vibing.Utils.Mote
---mote統合のメインエントリポイント
---後方互換性のためmote_diff.luaの全APIをre-export
local M = {}

local Binary = require("vibing.core.utils.mote.binary")
local Context = require("vibing.core.utils.mote.context")
local Operations = require("vibing.core.utils.mote.operations")
local Moteignore = require("vibing.core.utils.mote.moteignore")

-- Binary module exports
M.get_mote_path = Binary.get_path
M.is_available = Binary.is_available

-- Context module exports
M.build_context_name = Context.build_name
M.get_project_name = Context.get_project_name
M.build_context_dir_path = Context.build_dir_path
M.is_initialized = Context.is_initialized

-- Operations module exports
M.get_diff = Operations.get_diff
M.show_diff = Operations.show_diff
M.initialize = Operations.initialize
M.create_snapshot = Operations.create_snapshot
M.get_changed_files = Operations.get_changed_files
M.generate_patch = Operations.generate_patch

-- Moteignore module exports (internal API, prefixed with _)
M._ensure_moteignore_exists = Moteignore.ensure_exists

return M
