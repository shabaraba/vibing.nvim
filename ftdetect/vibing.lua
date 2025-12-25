---Filetype detection for vibing chat files
---Automatically sets filetype=vibing when opening *.vibing files
---@module "ftdetect.vibing"

vim.api.nvim_create_autocmd({ "BufRead", "BufNewFile" }, {
  pattern = "*.vibing",
  callback = function()
    vim.bo.filetype = "vibing"
  end,
})
