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

  -- Warm skills cache in background so first "/" press is instant
  local skills = require("vibing.infrastructure.completion.providers.skills")
  skills.preload()

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
  local has_cmp, cmp = pcall(require, "cmp")

  if not has_cmp then
    -- Fallback to omnifunc
    vim.bo[buf].omnifunc = "v:lua.require('vibing.application.completion').omnifunc"
  else
    -- cmp.setup.buffer()は呼び出し時点のカレントバッファに紐づくため、
    -- 非同期アタッチ経由（別バッファがカレントなタイミング）で呼ばれても
    -- 対象bufに設定されるようnvim_buf_callで明示的にスコープする
    vim.api.nvim_buf_call(buf, function()
      -- Prepend vibing source to existing sources for this buffer.
      -- setup_bufferはFileType再適用などで複数回呼ばれ得るため、既存のvibing
      -- エントリを除外してから追加し直し、重複登録を防ぐ
      local existing_sources = cmp.get_config().sources or {}
      local sources = { { name = "vibing", priority = 1000 } }
      for _, src in ipairs(existing_sources) do
        if src.name ~= "vibing" then
          table.insert(sources, src)
        end
      end
      cmp.setup.buffer({ sources = sources })
    end)
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
