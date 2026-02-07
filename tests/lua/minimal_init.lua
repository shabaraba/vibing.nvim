-- Minimal init for test environment
vim.opt.rtp:prepend(".")
vim.opt.rtp:prepend(vim.fn.stdpath("data") .. "/lazy/plenary.nvim")

-- Load plenary
vim.cmd("runtime plugin/plenary.vim")

-- Set test environment flag
vim.g.md_test_mode = true
