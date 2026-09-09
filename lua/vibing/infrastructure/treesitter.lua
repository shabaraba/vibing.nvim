---Tree-sitter setup for chat buffers.
---
---When the bundled outer parser is available, it owns only vibing.nvim section and tool
---boundaries. Each ordinary content chunk is parsed by the existing Markdown parser through a
---language injection. If the native parser was not built (for example no C compiler was available
---during installation), keep the previous Markdown-parser mapping as a graceful fallback.
local M = {}

local outer_parser_available = false

---Load the bundled parser or install the legacy Markdown mapping.
---@return boolean available Whether the outer vibing parser is active
function M.setup()
  outer_parser_available = false

  local language = vim.treesitter and vim.treesitter.language
  if language and type(language.add) == "function" then
    local ok, loaded = pcall(language.add, "vibing")
    outer_parser_available = ok and loaded == true
  end

  if outer_parser_available then
    -- setup() can be called again in a live session which previously registered the Markdown
    -- fallback. Explicitly restore the identity mapping in that case.
    pcall(vim.treesitter.language.register, "vibing", "vibing")
  else
    pcall(vim.treesitter.language.register, "markdown", "vibing")
  end

  return outer_parser_available
end

---Use the custom filetype only when its parser loaded successfully.
---Keeping `markdown` when it did not preserves highlighting and render-markdown.nvim behavior on
---machines where the optional native build was skipped.
---@param bufnr number
function M.apply_filetype(bufnr)
  if outer_parser_available
    and vim.api.nvim_buf_is_valid(bufnr)
    and vim.bo[bufnr].filetype ~= "vibing"
  then
    vim.bo[bufnr].filetype = "vibing"
  end
end

---@return boolean
function M.is_active()
  return outer_parser_available
end

return M
