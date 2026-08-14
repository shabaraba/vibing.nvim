-- Verify the Vim help files under doc/ the way Vim itself would read them.
--
-- Usage:
--   nvim --headless -l scripts/check-help.lua [doc-dir]
--
-- Exits 0 when everything passes, 1 with one line per problem otherwise. The directory argument
-- exists so tests/help-check.test.mjs can point it at a deliberately broken fixture -- a gate
-- nothing can fail is not a gate.

local MAX_WIDTH = 78

-- `    1. Introduction ....... |vibing-introduction|` -- a CONTENTS row. The leader is left
-- unconstrained: dots and plain spaces are both ordinary vimdoc style, and requiring dots made
-- the whole CONTENTS check below silently skip a space-aligned file.
local CONTENTS_ROW = '^%s*(%d+)%.%s+.*|(%S-)|%s*$'
-- `1. INTRODUCTION            *vibing-introduction*` -- a section heading. Anchored at column 0,
-- which is what keeps a heading-shaped line inside an indented `>` code example from matching.
local SECTION_HEADING = '^(%d+)%.%s+%S.-%s+%*([^%*%s]+)%*%s*$'

local doc_dir = (arg and arg[1]) or 'doc'
local problems = {}

local function fail(fmt, ...)
  table.insert(problems, string.format(fmt, ...))
end

--- The lines inside the CONTENTS section, or nil when the file has no CONTENTS heading.
---
--- Scoping matters: CONTENTS_ROW cannot be anchored at column 0 the way SECTION_HEADING is, since
--- its rows are indented. Run over the whole file it also matches an ordinary body line that ends
--- in a `|tag|` reference -- `    4. See |vibing-commands|` in a troubleshooting list, say --
--- which shifts every index after it and reports a section that is present as missing.
local function contents_block(lines)
  local first = nil
  for index, line in ipairs(lines) do
    if not first then
      if line:match('^CONTENTS%f[%W]') then
        first = index
      end
    elseif line:match('^=====') then
      return vim.list_slice(lines, first + 1, index - 1)
    end
  end
  return first and vim.list_slice(lines, first + 1) or nil
end

--- The `{ number, tag }` of every line matching `pattern`, in the order they appear.
local function numbered_rows(lines, pattern)
  local rows = {}
  for _, line in ipairs(lines) do
    local number, tag = line:match(pattern)
    if number then
      table.insert(rows, { number = tonumber(number), tag = tag })
    end
  end
  return rows
end

-- 1. helptags must be generatable. Duplicate or malformed tags fail here, and only here --
-- a stray `*template*` slipped through manual review during #531 exactly this way.
--
-- `:helptags` raises a Vim error rather than setting an exit code, so pcall is what catches it;
-- nvim would otherwise print the message and still exit 0.
local ok, err = pcall(vim.cmd, 'helptags ' .. vim.fn.fnameescape(doc_dir))
if not ok then
  fail('helptags: %s', (tostring(err):gsub('.*Vim%(helptags%):', '')))
end

local files = vim.fn.glob(doc_dir .. '/*.txt', false, true)
if #files == 0 then
  fail('%s contains no *.txt help file', doc_dir)
end

for _, file in ipairs(files) do
  local lines = vim.fn.readfile(file)
  local name = vim.fn.fnamemodify(file, ':t')

  -- 2. The 78-column convention. Measured with strdisplaywidth, not a byte or character count:
  -- a byte count reports the • and — already in vibing.txt as overlong, and a character count
  -- would under-report CJK, which occupies two columns.
  for lnum, line in ipairs(lines) do
    local width = vim.fn.strdisplaywidth(line)
    if width > MAX_WIDTH then
      fail('%s:%d: %d columns, over the %d-column limit', name, lnum, width, MAX_WIDTH)
    end
  end

  -- 3. CONTENTS and the body must agree, entry by entry, on both number and tag. Comparing them
  -- in order covers a mistyped link too: a heading only matches SECTION_HEADING if it defines
  -- its own tag, so an entry pointing at a tag nothing defines shows up as a mismatch here.
  --
  -- This fails closed. Keying it on "did we parse any entries" instead would let one unreadable
  -- CONTENTS block disable the check while still reporting OK, which is the exact failure #542
  -- was filed about -- so a file with a CONTENTS heading and no parseable rows is a problem,
  -- not a pass. A file with no CONTENTS heading at all has nothing to disagree with.
  local block = contents_block(lines)
  local entries = block and numbered_rows(block, CONTENTS_ROW) or {}

  if block and #entries == 0 then
    fail('%s: CONTENTS block found but no `N. Title |tag|` rows could be read from it', name)
  elseif block then
    local headings = numbered_rows(lines, SECTION_HEADING)

    for index = 1, math.max(#entries, #headings) do
      local entry, heading = entries[index], headings[index]
      if not heading then
        fail('%s: CONTENTS lists %d. |%s| but the body has no matching section', name, entry.number, entry.tag)
      elseif not entry then
        fail('%s: section %d. *%s* is missing from CONTENTS', name, heading.number, heading.tag)
      elseif heading.number ~= entry.number or heading.tag ~= entry.tag then
        fail(
          '%s: CONTENTS entry %d. |%s| does not match section %d. *%s*',
          name,
          entry.number,
          entry.tag,
          heading.number,
          heading.tag
        )
      end
    end
  end
end

if #problems > 0 then
  io.stderr:write(('%s: %d problem(s)\n'):format(doc_dir, #problems))
  for _, problem in ipairs(problems) do
    io.stderr:write('  ' .. problem .. '\n')
  end
  os.exit(1)
end

print(('%s: %d help file(s) OK'):format(doc_dir, #files))
