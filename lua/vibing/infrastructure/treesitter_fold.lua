---Fold levels for chat buffers, computed from vibing.nvim's own nodes and nothing else.
---
---`vim.treesitter.foldexpr()` cannot be used here. It walks every tree in the injection stack and
---applies each injected language's own `folds.scm`: a chat injects markdown, and markdown injects
---yaml into the frontmatter, so the stock queries fold every section heading, every list and every
---frontmatter key -- most of the file. This asks the outer tree only, so what folds is exactly what
---`queries/vibing/folds.scm` names.
local M = {}

---@class Vibing.FoldRegion
---@field srow integer First row of the region, 0-indexed
---@field erow integer Last row of the region, 0-indexed and inclusive
---@field kind string The node type, so only like merges with like

---@class Vibing.FoldState
---@field tick integer The `changedtick` the regions were derived at
---@field raw Vibing.FoldRegion[] One per `@fold` capture, in document order
---@field merged Vibing.FoldRegion[] Runs of the same kind joined, in document order

---@type table<integer, Vibing.FoldState>
local state = {}
---@type table<integer, true>
local watched = {}
---Changed rows accumulated since the last refresh, as `{ srow, erow }`.
---@type table<integer, integer[]>
local pending = {}
---The lowest row whose regions may have changed since the last derivation.
---@type table<integer, integer>
local dirty_from = {}

local function forget(bufnr)
  state[bufnr], watched[bufnr], pending[bufnr], dirty_from[bufnr] = nil, nil, nil, nil
end

vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
  group = vim.api.nvim_create_augroup("VibingTreesitterFold", { clear = true }),
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
---@param seed Vibing.FoldRegion? A merged region the first of `found` may extend
---@return Vibing.FoldRegion[]
local function merge_runs(bufnr, found, seed)
  local merged = {}
  if seed then
    merged[1] = { srow = seed.srow, erow = seed.erow, kind = seed.kind }
  end

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

---Read the `@fold` captures of the outer tree from `srow` to the end of the buffer.
---@param bufnr integer
---@param srow integer
---@return Vibing.FoldRegion[]? regions nil when the buffer has no usable outer tree
local function capture_regions(bufnr, srow)
  local ok_parser, parser = pcall(vim.treesitter.get_parser, bufnr, "vibing")
  if not ok_parser or not parser then
    return nil
  end

  local query = vim.treesitter.query.get("vibing", "folds")
  if not query then
    return nil
  end

  -- `false` parses the outer tree and stops. That is both the tree this needs and the reason a
  -- foldexpr can run on every change without paying for the injection parse again.
  local ok_parse, trees = pcall(parser.parse, parser, false)
  if not ok_parse or type(trees) ~= "table" or not trees[1] then
    return nil
  end

  local found = {}
  for _, node in query:iter_captures(trees[1]:root(), bufnr, srow, -1) do
    local start_row, _, end_row, end_col = node:range()
    -- A node ending at column 0 stops before that row rather than on it.
    if end_col == 0 then
      end_row = end_row - 1
    end
    if end_row >= start_row and start_row >= srow then
      found[#found + 1] = { srow = start_row, erow = end_row, kind = node:type() }
    end
  end

  return found
end

---How many entries of `list` end strictly before `row`.
---@param list Vibing.FoldRegion[]
---@param row integer
---@return integer
local function count_below(list, row)
  local kept = 0
  for _, region in ipairs(list) do
    if region.erow >= row then
      break
    end
    kept = kept + 1
  end
  return kept
end

---Derive the buffer's fold regions, reusing everything the last change could not have moved.
---
---The whole-buffer form cost 12 ms per chunk flush on a 21471-line chat -- the largest in this
---repository -- and a flush happens every 50 ms while a turn streams, so it spent a quarter of the
---main loop. Nothing above the first changed row can move, though: the chat is appended to, and
---even a mid-buffer edit leaves every earlier node where it was. So the query starts at the splice
---point and the regions before it are carried over. Measured on that same chat, the cost of a
---flush stops depending on its length.
---@param bufnr integer
---@return Vibing.FoldRegion[] merged
local function derive(bufnr)
  local previous = state[bufnr]
  local from = dirty_from[bufnr]
  dirty_from[bufnr] = nil

  -- A change on a row can extend the block that began on the one above it -- a tool call gaining
  -- its first result line -- so the row above is re-read too.
  local splice = (previous and from) and math.max(from - 1, 0) or 0
  local raw, merged = {}, {}

  if previous and from then
    local kept_raw = count_below(previous.raw, splice)
    if kept_raw > 0 then
      splice = previous.raw[kept_raw].erow + 1
      vim.list_extend(raw, previous.raw, 1, kept_raw)
    else
      splice = 0
    end
    vim.list_extend(merged, previous.merged, 1, count_below(previous.merged, splice))
  end

  local found = capture_regions(bufnr, splice)
  if not found then
    return {}
  end

  vim.list_extend(raw, found)
  -- The last carried-over merged region may absorb the first newly read one, so it re-merges
  -- rather than being trusted as final.
  local seed = table.remove(merged)
  vim.list_extend(merged, merge_runs(bufnr, found, seed))

  state[bufnr] = { tick = vim.b[bufnr].changedtick, raw = raw, merged = merged }
  return merged
end

---@param bufnr integer
---@return Vibing.FoldRegion[]
local function regions(bufnr)
  local entry = state[bufnr]
  if entry and entry.tick == vim.b[bufnr].changedtick then
    return entry.merged
  end
  return derive(bufnr)
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

---Grow a changed range to cover whole folds at both ends.
---
---A run gaining another call moves the *end* of a region that opened earlier, so re-deriving only
---the rows that changed leaves the opening row saying what it said before.
---@param bufnr integer
---@param srow integer
---@param erow integer
---@return integer srow, integer erow
local function widen_to_folds(bufnr, srow, erow)
  local entry = state[bufnr]
  if not entry then
    return srow, erow
  end

  local first = region_at(entry.merged, srow)
  if first then
    srow = first.srow
  end
  local last = region_at(entry.merged, erow)
  if last then
    erow = last.erow + 1
  end

  return srow, erow
end

---Ask Neovim to re-derive the folds of every window showing this buffer.
---
---Neovim does not reliably re-evaluate `foldexpr` for lines it did not itself change, and a run of
---tool calls grows the *extent* of a fold that opened earlier: the window kept a fold ending where
---the run's first call ended, and read the rest of the run as ordinary content. Observed mid-turn
---on a live chat -- rows 133..140 at level 0 against a tree that said 1 -- and repaired by nothing
---more than `setlocal foldmethod=expr`. `vim.treesitter`'s own fold module carries this same
---explicit refresh, under the same stated reason: "Nvim usually automatically updates folds when
---text changes, but it doesn't work here".
---@param bufnr integer
local function refresh_folds(bufnr)
  local range = pending[bufnr]
  pending[bufnr] = nil

  if not range or type(vim._foldupdate) ~= "function" or not vim.api.nvim_buf_is_loaded(bufnr) then
    return
  end

  local last = vim.api.nvim_buf_line_count(bufnr)
  local srow, erow = widen_to_folds(bufnr, math.max(range[1], 0), math.min(range[2], last))
  erow = math.min(erow, last)
  if srow >= erow then
    return
  end

  for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
    if vim.api.nvim_get_option_value("foldmethod", { win = win }) == "expr" then
      vim._foldupdate(win, srow, erow)
    end
  end
end

---Refresh once per batch of changes, and not while the user is typing.
---
---Neovim guards its own fold update in insert mode, so one made there is silently dropped -- and
---the chat's next message is written in insert mode, right under the turn that is still streaming.
---@param bufnr integer
---@param srow integer First changed row, 0-indexed
---@param erow integer Row after the last changed one
local function schedule_refresh(bufnr, srow, erow)
  local range = pending[bufnr]
  if range then
    range[1], range[2] = math.min(range[1], srow), math.max(range[2], erow)
    return
  end
  pending[bufnr] = { srow, erow }

  if vim.api.nvim_get_mode().mode:match("^i") then
    vim.api.nvim_create_autocmd("InsertLeave", {
      buffer = bufnr,
      once = true,
      callback = function()
        refresh_folds(bufnr)
      end,
    })
    return
  end

  vim.schedule(function()
    refresh_folds(bufnr)
  end)
end

---@param bufnr integer
local function watch(bufnr)
  if watched[bufnr] then
    return
  end
  watched[bufnr] = true

  vim.api.nvim_buf_attach(bufnr, false, {
    on_lines = function(_, buf, _, firstline, _, new_lastline)
      if not watched[buf] then
        return true
      end
      dirty_from[buf] = math.min(dirty_from[buf] or firstline, firstline)
      schedule_refresh(buf, firstline, new_lastline)
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

  local row = lnum - 1
  local region = region_at(regions(bufnr), row)
  if not region then
    return "0"
  end
  return row == region.srow and ">1" or "1"
end

return M
