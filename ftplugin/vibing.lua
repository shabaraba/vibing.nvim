-- vibing filetype plugin
-- Sets up completion and inherits markdown settings

-- Inherit markdown settings
vim.bo.syntax = "markdown"
vim.bo.commentstring = "<!-- %s -->"

-- Set up omni-completion for slash commands
vim.bo.omnifunc = "v:lua.require'vibing.completion'.slash_command_complete"

-- Enable completion menu
vim.bo.completeopt = "menu,menuone,noselect"

-- Markdown-like settings
vim.bo.textwidth = 0
vim.bo.formatoptions = "tcqj"
vim.wo.conceallevel = 2

-- Enable spell checking (optional, can be disabled by user)
vim.wo.spell = false
