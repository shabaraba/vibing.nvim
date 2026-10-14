--- Prints the argv a backend descriptor builds, so a stream capture is taken with the command
--- vibing.nvim actually spawns rather than a hand-written one. See README.md for the full recipe.
---
--- VIBING_BACKEND, VIBING_PROMPT, VIBING_CWD, VIBING_PERMISSION_MODE and VIBING_OUT are read from
--- the environment; the argv lands in VIBING_OUT as one JSON array.
local Config = require("vibing.config")
Config.setup({})

local Agents = require("vibing.core.constants.agents")
local descriptor = require(Agents.get(vim.env.VIBING_BACKEND).descriptor_module)

local opts = {
  cwd = vim.env.VIBING_CWD,
  permission_mode = vim.env.VIBING_PERMISSION_MODE,
}

-- No hook argument: the capture is of the stream, and a hook with no Neovim listening would stall
-- the turn waiting for a decision nothing can answer.
local ok, cmd = pcall(descriptor.build, vim.env.VIBING_PROMPT, opts, nil, Config.get(), nil)
if not ok then
  vim.fn.writefile({ "ERROR: " .. tostring(cmd) }, vim.env.VIBING_OUT)
  vim.cmd("cquit 1")
end

vim.fn.writefile({ vim.json.encode(cmd) }, vim.env.VIBING_OUT)
vim.cmd("quit")
