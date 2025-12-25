-- Auto-detect .vibing files and set filetype
vim.api.nvim_create_autocmd({ "BufRead", "BufNewFile" }, {
  pattern = "*.vibing",
  callback = function()
    vim.bo.filetype = "vibing"
  end,
})
