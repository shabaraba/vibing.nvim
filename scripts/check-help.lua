-- Verify the Vim help files under doc/ the way Vim itself would read them.
--
-- Nothing in CI looked at doc/*.txt before this: `npm run check` only compiles lua/, and the
-- prettier/eslint/markdownlint steps do not match `.txt`. The helptags, the 78-column rule and
-- the CONTENTS/tag correspondence were all verified by hand while writing #531, which is why
-- they were about to rot (#542).
--
-- Usage:
--   nvim --headless -l scripts/check-help.lua [doc-dir]
--
-- Exits 0 when everything passes, 1 with one line per problem otherwise. The directory argument
-- exists so tests/help-check.test.mjs can point it at a deliberately broken fixture -- a gate
-- nothing can fail is not a gate.

local MAX_WIDTH = 78

local doc_dir = (arg and arg[1]) or 'doc'
local problems = {}

local function fail(fmt, ...)
  table.insert(problems, string.format(fmt, ...))
end

--- Every `*tag*` the file defines. Vim's own definition: an asterisk-delimited run with no
--- whitespace or asterisk inside it.
local function defined_tags(lines)
  local tags = {}
  for _, line in ipairs(lines) do
    for tag in line:gmatch('%*([^%*%s]+)%*') do
      tags[tag] = true
    end
  end
  return tags
end

--- The `N. Title ....... |tag|` rows of the CONTENTS block, in the order they appear.
local function contents_entries(lines)
  local entries = {}
  for _, line in ipairs(lines) do
    local number, tag = line:match('^%s*(%d+)%.%s+.-%s%.%.+%s*|(%S-)|%s*$')
    if number then
      table.insert(entries, { number = tonumber(number), tag = tag })
    end
  end
  return entries
end

--- The `N. HEADING                *tag*` section headings, in the order they appear.
local function section_headings(lines)
  local headings = {}
  for _, line in ipairs(lines) do
    local number, tag = line:match('^(%d+)%.%s+%S.-%s+%*([^%*%s]+)%*%s*$')
    if number then
      table.insert(headings, { number = tonumber(number), tag = tag })
    end
  end
  return headings
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

  -- 3. CONTENTS must agree with the body: every entry links to a tag that exists, and the
  -- section headings carry the same numbers and tags in the same order.
  local entries = contents_entries(lines)
  if #entries > 0 then
    local tags = defined_tags(lines)
    for _, entry in ipairs(entries) do
      if not tags[entry.tag] then
        fail('%s: CONTENTS entry %d links to |%s|, which no *%s* defines', name, entry.number, entry.tag, entry.tag)
      end
    end

    local headings = section_headings(lines)
    for index, entry in ipairs(entries) do
      local heading = headings[index]
      if not heading then
        fail('%s: CONTENTS lists %d. |%s| but the body has no matching section', name, entry.number, entry.tag)
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
    if #headings > #entries then
      local extra = headings[#entries + 1]
      fail('%s: section %d. *%s* is missing from CONTENTS', name, extra.number, extra.tag)
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
