---Fold levels for chat buffers, computed from vibing.nvim's own nodes and nothing else.
---
---`vim.treesitter.foldexpr()` cannot be used here. It walks every tree in the injection stack and
---applies each injected language's own `folds.scm`: a chat injects markdown, and markdown injects
---yaml into the frontmatter, so the stock queries fold every section heading, every list and every
---frontmatter key -- most of the file. This asks the outer tree only, so what folds is exactly what
---`queries/vibing/folds.scm` names.
local M = {}

---@class Vibing.FoldLevels
---@field tick integer The `changedtick` the levels were computed at
---@field levels table<integer, integer> 0-indexed row -> how many folds cover it

---@type table<integer, Vibing.FoldLevels>
local cache = {}

vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
  group = vim.api.nvim_create_augroup("VibingTreesitterFold", { clear = true }),
  callback = function(args)
    cache[args.buf] = nil
  end,
})

---@class Vibing.FoldRegion
---@field srow integer First row of the region, 0-indexed
---@field erow integer Last row of the region, 0-indexed and inclusive
---@field kind string The node type, so only like merges with like

---Whether the rows strictly between two regions are all blank.
---@param bufnr integer
---@param after integer Last row of the earlier region
---@param before integer First row of the later region
---@return boolean
local function only_blank_between(bufnr, after, before)
  for _, line in ipairs(vim.api.nvim_buf_get_lines(bufnr, after + 1, before, false)) do
    if line:match("%S") then
      return false
    end
  end
  return true
end

---Join runs of the same node type into one region each.
---
---The renderer puts a blank line between consecutive tool calls, so a turn that ran four of them
---in a row produced four folds -- and each one-line call among them stayed open regardless, since
---Neovim does not close a fold shorter than `foldminlines`. A run is one thing the reader is
---skipping past, so it collapses as one. Only like merges with like: reasoning that happens to sit
---against a tool call keeps its own fold rather than disappearing under the tool's first line.
---@param bufnr integer
---@param found Vibing.FoldRegion[] In document order
---@return Vibing.FoldRegion[]
local function merge_runs(bufnr, found)
  local merged = {}

  for _, region in ipairs(found) do
    local previous = merged[#merged]
    if
      previous
      and previous.kind == region.kind
      and region.srow > previous.erow
      and only_blank_between(bufnr, previous.erow, region.srow)
    then
      previous.erow = region.erow
    else
      merged[#merged + 1] = { srow = region.srow, erow = region.erow, kind = region.kind }
    end
  end

  return merged
end

---@param bufnr integer
---@return table<integer, integer> levels 0-indexed row -> how many folds cover it
local function compute(bufnr)
  local levels = {}

  local ok_parser, parser = pcall(vim.treesitter.get_parser, bufnr, "vibing")
  if not ok_parser or not parser then
    return levels
  end

  local query = vim.treesitter.query.get("vibing", "folds")
  if not query then
    return levels
  end

  -- `false` parses the outer tree and stops. That is both the tree this needs and the reason a
  -- foldexpr can run on every change without paying for the injection parse again.
  local ok_parse, trees = pcall(parser.parse, parser, false)
  if not ok_parse or type(trees) ~= "table" or not trees[1] then
    return levels
  end

  local found = {}
  for _, node in query:iter_captures(trees[1]:root(), bufnr) do
    local srow, _, erow, ecol = node:range()
    -- A node ending at column 0 stops before that row rather than on it.
    if ecol == 0 then
      erow = erow - 1
    end
    if erow >= srow then
      found[#found + 1] = { srow = srow, erow = erow, kind = node:type() }
    end
  end

  for _, region in ipairs(merge_runs(bufnr, found)) do
    for row = region.srow, region.erow do
      levels[row] = (levels[row] or 0) + 1
    end
  end

  return levels
end

---@param lnum integer 1-indexed line, as `foldexpr` is handed it
---@return string
function M.foldexpr(lnum)
  local bufnr = vim.api.nvim_get_current_buf()

  local tick = vim.b[bufnr].changedtick
  local entry = cache[bufnr]
  if not entry or entry.tick ~= tick then
    entry = { tick = tick, levels = compute(bufnr) }
    cache[bufnr] = entry
  end

  local row = lnum - 1
  local level = entry.levels[row] or 0
  local previous = row > 0 and (entry.levels[row - 1] or 0) or 0

  if level > previous then
    return ">" .. level
  end
  return tostring(level)
end

return M
