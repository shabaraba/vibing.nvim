---Fold levels for chat buffers, computed from vibing.nvim's own nodes and nothing else.
---
---`vim.treesitter.foldexpr()` cannot be used here. It walks every tree in the injection stack and
---applies each injected language's own `folds.scm`: a chat injects markdown, and markdown injects
---yaml into the frontmatter, so the stock queries fold every section heading, every list and every
---frontmatter key -- most of the file. This asks the outer tree only, so what folds is exactly what
---`queries/vibing/folds.scm` names.
---
---**Folds are derived when a turn ends, not while it streams.** A turn's tool calls arrive one
---50ms chunk at a time and the run they belong to is not finished until the turn is, so folding
---each delta as it lands means re-deriving the chat dozens of times a second to draw a fold that
---is about to change again. What a reader wants to skip past is the finished run. So a streaming
---turn costs no derivation at all -- its output is simply not folded yet -- and
---`VibingResponseDone` folds the whole thing in one pass.
local M = {}

---@class Vibing.FoldRegion
---@field srow integer First row of the region, 0-indexed
---@field erow integer Last row of the region, 0-indexed and inclusive
---@field kind string The node type, so only like merges with like

---The regions last derived for a buffer, in document order and non-overlapping.
---@type table<integer, Vibing.FoldRegion[]>
local regions = {}
---Buffers whose text was edited in a way that could have moved one of their regions.
---@type table<integer, true>
local stale = {}
---@type table<integer, true>
local watched = {}

local function forget(bufnr)
  regions[bufnr], stale[bufnr], watched[bufnr] = nil, nil, nil
end

local group = vim.api.nvim_create_augroup("VibingTreesitterFold", { clear = true })

vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
  group = group,
  callback = function(args)
    forget(args.buf)
  end,
})

---Whether the rows strictly between two regions are all blank.
---@param bufnr integer
---@param after integer Last row of the earlier region
---@param before integer First row of the later region
---@return boolean
local function only_blank_between(bufnr, after, before)
  if before <= after + 1 then
    return true
  end
  for _, line in ipairs(vim.api.nvim_buf_get_lines(bufnr, after + 1, before, false)) do
    if line:match("%S") then
      return false
    end
  end
  return true
end

---Join runs of the same node type into one region each.
---
---The renderer puts a blank line between consecutive tool calls, so a turn that ran ten of them in
---a row produced ten folds, each one line long and each carrying its own fold text. A run is one
---thing the reader is skipping past, so it collapses as one. Only like merges with like: reasoning
---that happens to sit against a tool call keeps its own fold rather than disappearing under the
---tool's first line.
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

---Read every `@fold` capture of the outer tree.
---@param bufnr integer
---@return Vibing.FoldRegion[]? regions nil when the buffer has no usable outer tree
local function capture_regions(bufnr)
  local ok_parser, parser = pcall(vim.treesitter.get_parser, bufnr, "vibing")
  if not ok_parser or not parser then
    return nil
  end

  local query = vim.treesitter.query.get("vibing", "folds")
  if not query then
    return nil
  end

  -- `false` parses the outer tree and stops. That is both the tree this needs and the reason the
  -- derivation does not pay for the injection parse.
  local ok_parse, trees = pcall(parser.parse, parser, false)
  if not ok_parse or type(trees) ~= "table" or not trees[1] then
    return nil
  end

  local found = {}
  for _, node in query:iter_captures(trees[1]:root(), bufnr) do
    local start_row, _, end_row, end_col = node:range()
    -- A node ending at column 0 stops before that row rather than on it.
    if end_col == 0 then
      end_row = end_row - 1
    end
    if end_row >= start_row then
      found[#found + 1] = { srow = start_row, erow = end_row, kind = node:type() }
    end
  end

  return found
end

---@param bufnr integer
---@return Vibing.FoldRegion[]
local function derive(bufnr)
  local found = capture_regions(bufnr)
  if not found then
    return {}
  end

  stale[bufnr] = nil
  regions[bufnr] = merge_runs(bufnr, found)
  return regions[bufnr]
end

---The region covering `row`, if any.
---@param merged Vibing.FoldRegion[] In document order, non-overlapping
---@param row integer
---@return Vibing.FoldRegion?
local function region_at(merged, row)
  local low, high = 1, #merged
  while low <= high do
    local mid = math.floor((low + high) / 2)
    local region = merged[mid]
    if row < region.srow then
      high = mid - 1
    elseif row > region.erow then
      low = mid + 1
    else
      return region
    end
  end
  return nil
end

---Derive the buffer's folds and ask every window drawing them to re-read the result.
---
---Neovim does not re-evaluate `foldexpr` for lines it did not itself change, and a finished turn
---moves the *extent* of folds whose opening row never changed. `vim.treesitter`'s own fold module
---carries this same explicit refresh, under the same stated reason: "Nvim usually automatically
---updates folds when text changes, but it doesn't work here".
---@param bufnr integer
local function refresh(bufnr)
  if not vim.api.nvim_buf_is_loaded(bufnr) then
    return
  end

  local windows = {}
  for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
    if vim.api.nvim_get_option_value("foldmethod", { win = win }) == "expr" then
      windows[#windows + 1] = win
    end
  end

  if #windows == 0 then
    -- Nothing is drawing folds for it, so derive when something is.
    regions[bufnr], stale[bufnr] = nil, nil
    return
  end

  derive(bufnr)

  if type(vim._foldupdate) ~= "function" then
    return
  end
  local last = vim.api.nvim_buf_line_count(bufnr)
  for _, win in ipairs(windows) do
    vim._foldupdate(win, 0, last)
  end
end

---Fold what a finished turn wrote.
---
---Deferred out of insert mode, because Neovim drops a fold update made there -- and the chat's
---next message is typed in insert mode, right under the turn that just ended.
---@param bufnr integer
function M.refresh(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  if vim.api.nvim_get_mode().mode:match("^i") then
    vim.api.nvim_create_autocmd("InsertLeave", {
      buffer = bufnr,
      once = true,
      callback = function()
        refresh(bufnr)
      end,
    })
    return
  end

  refresh(bufnr)
end

vim.api.nvim_create_autocmd("User", {
  group = group,
  pattern = "VibingResponseDone",
  callback = function(args)
    local bufnr = args.data and args.data.bufnr
    if type(bufnr) == "number" then
      M.refresh(bufnr)
    end
  end,
})

vim.api.nvim_create_autocmd("InsertLeave", {
  group = group,
  callback = function(args)
    if stale[args.buf] then
      refresh(args.buf)
    end
  end,
})

---Notice an edit that could have moved a region that is already folded.
---
---Everything a streaming turn writes lands below the last region, so a turn marks nothing stale
---and costs nothing. A user rewriting an older message does move them, and that is re-derived on
---the next `foldexpr` Neovim asks for.
---@param bufnr integer
local function watch(bufnr)
  if watched[bufnr] then
    return
  end
  watched[bufnr] = true

  vim.api.nvim_buf_attach(bufnr, false, {
    on_lines = function(_, buf, _, firstline)
      if not watched[buf] then
        return true
      end
      local known = regions[buf]
      local last = known and known[#known]
      if last and firstline <= last.erow then
        stale[buf] = true
      end
    end,
    on_detach = function(_, buf)
      forget(buf)
    end,
  })
end

---@param lnum integer 1-indexed line, as `foldexpr` is handed it
---@return string
function M.foldexpr(lnum)
  local bufnr = vim.api.nvim_get_current_buf()
  watch(bufnr)

  local merged = regions[bufnr]
  if not merged or stale[bufnr] then
    merged = derive(bufnr)
  end

  local row = lnum - 1
  local region = region_at(merged, row)
  if not region then
    return "0"
  end
  return row == region.srow and ">1" or "1"
end

return M
