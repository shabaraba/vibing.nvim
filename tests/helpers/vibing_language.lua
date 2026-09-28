--- Test seam for specs that need the `vibing` Tree-sitter language registered.
---
--- The grammar is built from its committed source rather than from `parser/vibing.so`, so a spec
--- tests the checkout it was run against and not whatever was compiled last. Registration is
--- global and `PlenaryBustedDirectory` runs one Neovim per spec file, so the result is memoized
--- per process; without that every `it` would pay the compile.
--- @module tests.helpers.vibing_language

local M = {}

local registered = false

--- Compile and register the grammar, once per Neovim.
--- @return nil
function M.ensure()
  if registered then
    return
  end

  local parser_source = assert(
    vim.api.nvim_get_runtime_file("tree-sitter-vibing/src/parser.c", false)[1],
    "generated parser source is missing"
  )
  local include_dir = vim.fn.fnamemodify(parser_source, ":h")
  local parser_library = vim.fn.tempname() .. ".so"

  local compile = vim.system({
    "cc",
    "-O2",
    "-shared",
    "-fPIC",
    "-I" .. include_dir,
    parser_source,
    include_dir .. "/scanner.c",
    "-o",
    parser_library,
  }, { text = true }):wait()
  assert(compile.code == 0, compile.stderr)

  assert(vim.treesitter.language.add("vibing", { path = parser_library }))
  registered = true
end

return M
