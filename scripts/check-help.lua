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

--- `    2.1 Sub-heading ....` -- a sub-section, which neither pattern above can read, because both
--- require whitespace straight after the dot. Detected explicitly so it fails rather than being
--- dropped from the comparison without a word: silently skipping is the failure mode this whole
--- checker exists to prevent.
local SUBSECTION_ROW = '^%s*%d+%.%d'

--- Where the CONTENTS section starts and ends, or nil when the file has no CONTENTS heading.
---
--- Scoping matters in both directions. CONTENTS_ROW cannot be anchored at column 0 the way
--- SECTION_HEADING is, since its rows are indented; run over the whole file it also matches an
--- ordinary body line ending in a `|tag|` reference -- `    4. See |vibing-commands|` in a
--- troubleshooting list, say. And scanning for headings *inside* the CONTENTS block would rely on
--- the two patterns never overlapping, which is true today only because one ends in `|tag|` and
--- the other in `*tag*`. Neither side has to depend on that.
---
--- @return integer? first line after the CONTENTS heading
--- @return integer? last line before the rule that closes the section
local function contents_range(lines)
  local first = nil
  for index, line in ipairs(lines) do
    if not first then
      if line:match('^CONTENTS%f[%W]') then
        first = index + 1
      end
    elseif line:match('^=====') then
      return first, index - 1
    end
  end
  return first, first and #lines or nil
end

--- The `{ number, tag }` of every line matching `pattern` within `range`, in the order they appear.
--- @param range table? `{ from, to }` line bounds, or nil for the whole list
local function numbered_rows(lines, pattern, range)
  local rows = {}
  for index, line in ipairs(lines) do
    local inside = range == nil or (index >= range.from and index <= range.to)
    if inside then
      local number, tag = line:match(pattern)
      if number then
        table.insert(rows, { number = tonumber(number), tag = tag, lnum = index })
      end
    end
  end
  return rows
end

--- Rows keyed by their section number, plus any number that appeared more than once.
---
--- Keying by number rather than by position is what keeps one mistake to one message. Walking the
--- two lists in parallel meant a single inserted or renumbered section shifted everything after
--- it, so one typo reported as a cascade and the first message named a section that was fine.
local function by_number(rows)
  local map, duplicates = {}, {}
  for _, row in ipairs(rows) do
    if map[row.number] then
      table.insert(duplicates, row.number)
    else
      map[row.number] = row
    end
  end
  return map, duplicates
end

--- Every number present in either side, ascending, so diagnostics come out in document order.
local function all_numbers(a, b)
  local seen, numbers = {}, {}
  for _, map in ipairs({ a, b }) do
    for number in pairs(map) do
      if not seen[number] then
        seen[number] = true
        table.insert(numbers, number)
      end
    end
  end
  table.sort(numbers)
  return numbers
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

  -- 3. CONTENTS and the body must agree, section number by section number, on the tag. That also
  -- covers a mistyped link: a heading only matches SECTION_HEADING if it defines its own tag, so
  -- an entry pointing at a tag nothing defines has no heading to pair with.
  --
  -- This fails closed. Keying it on "did we parse any entries" instead would let one unreadable
  -- CONTENTS block disable the check while still reporting OK, which is the exact failure #542
  -- was filed about -- so a file with a CONTENTS heading and no parseable rows is a problem,
  -- not a pass. A file with no CONTENTS heading at all has nothing to disagree with.
  local from, to = contents_range(lines)
  if not from then
    goto continue
  end

  do
    local contents = { from = from, to = to }
    local entries = numbered_rows(lines, CONTENTS_ROW, contents)

    -- Sub-sections read as neither an entry nor a heading, so they would drop out of the
    -- comparison unannounced. Say so instead; supporting them is a deliberate decision, not
    -- something to discover from a green run.
    for lnum, line in ipairs(lines) do
      if line:match(SUBSECTION_ROW) then
        fail('%s:%d: sub-section numbering (N.M) is not checked; flatten it or teach the checker', name, lnum)
      end
    end

    if #entries == 0 then
      fail('%s: CONTENTS block found but no `N. Title |tag|` rows could be read from it', name)
      goto continue
    end

    local headings = numbered_rows(lines, SECTION_HEADING, nil)
    -- Headings inside the CONTENTS block are not sections. Today the two patterns cannot both
    -- match one line, but nothing enforces that, so the range does the work instead.
    headings = vim.tbl_filter(function(row)
      return row.lnum < from or row.lnum > to
    end, headings)

    local entry_by_number, entry_dupes = by_number(entries)
    local heading_by_number, heading_dupes = by_number(headings)

    for _, number in ipairs(entry_dupes) do
      fail('%s: CONTENTS lists section %d more than once', name, number)
    end
    for _, number in ipairs(heading_dupes) do
      fail('%s: the body has more than one section numbered %d', name, number)
    end

    for _, number in ipairs(all_numbers(entry_by_number, heading_by_number)) do
      local entry, heading = entry_by_number[number], heading_by_number[number]
      if not heading then
        fail('%s: CONTENTS lists %d. |%s| but the body has no section %d', name, number, entry.tag, number)
      elseif not entry then
        fail('%s: section %d. *%s* is missing from CONTENTS', name, number, heading.tag)
      elseif entry.tag ~= heading.tag then
        fail('%s: section %d links to |%s| in CONTENTS but defines *%s*', name, number, entry.tag, heading.tag)
      end
    end
  end

  ::continue::
end

if #problems > 0 then
  io.stderr:write(('%s: %d problem(s)\n'):format(doc_dir, #problems))
  for _, problem in ipairs(problems) do
    io.stderr:write('  ' .. problem .. '\n')
  end
  os.exit(1)
end

print(('%s: %d help file(s) OK'):format(doc_dir, #files))
