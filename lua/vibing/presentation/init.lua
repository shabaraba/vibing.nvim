---@class Vibing.Presentation
---プレゼンテーション層のエントリポイント
local M = {}

-- Common
M.Window = require("vibing.presentation.common.window")

-- Inline
M.InlineProgressView = require("vibing.presentation.inline.progress_view")
M.OutputView = require("vibing.presentation.inline.output_view")

return M
