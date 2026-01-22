---@class Vibing.Completion
---Main entry point for vibing completion system
---Supports both nvim-cmp (preferred) and omnifunc (fallback)
local M = {}

local _setup_done = false

---Setup completion system
---Call this after vibing.setup() to initialize completion
function M.setup()
  if _setup_done then
    return
  end

  -- Try to setup nvim-cmp source
  local cmp_adapter = require("vibing.infrastructure.completion.adapters.cmp")
  local cmp_available = cmp_adapter.setup()

  if cmp_available then
    vim.notify("[vibing] nvim-cmp source registered", vim.log.levels.DEBUG)
  end

  _setup_done = true
end

---Omnifunc for vibing buffers (fallback when nvim-cmp is not available)
---@param findstart 0|1
---@param base string
---@return number|table
function M.omnifunc(findstart, base)
  local omnifunc_adapter = require("vibing.infrastructure.completion.adapters.omnifunc")
  return omnifunc_adapter.complete(findstart, base)
end

---Setup completion for a specific buffer
---@param buf number Buffer number
function M.setup_buffer(buf)
  local has_cmp = pcall(require, "cmp")

  if not has_cmp then
    -- Fallback to omnifunc
    vim.bo[buf].omnifunc = "v:lua.require('vibing.application.completion').omnifunc"
  end

  vim.bo[buf].completeopt = "menu,menuone,noselect"
end

---Clear all provider caches
function M.clear_cache()
  local skills = require("vibing.infrastructure.completion.providers.skills")
  local files = require("vibing.infrastructure.completion.providers.files")
  local agents = require("vibing.infrastructure.completion.providers.agents")

  skills.clear_cache()
  files.clear_cache()
  agents.clear_cache()
end

return M
