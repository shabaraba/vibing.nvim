-- vibing filetype plugin
-- Sets up completion and inherits markdown settings

-- Inherit markdown settings
vim.bo.syntax = "markdown"
vim.bo.commentstring = "<!-- %s -->"

-- Set up omni-completion for slash commands
vim.bo.omnifunc = "v:lua.require'vibing.completion'.slash_command_complete"

-- Configure completion menu for slash commands
-- These options ensure the omni-completion menu displays correctly:
-- - menu: show popup menu even with one match
-- - menuone: show menu even when there's only one match
-- - noselect: don't auto-select first match (user explicitly chooses)
vim.bo.completeopt = "menu,menuone,noselect"

-- Markdown-like settings
vim.bo.textwidth = 0
vim.bo.formatoptions = "tcqj"
vim.wo.conceallevel = 2

-- Disable spell checking by default (users can enable with :set spell)
vim.wo.spell = false
