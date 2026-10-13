-- Summary links are resolved from transcript evidence, never from the working directory.
local M = {}
local URL = "https://github%.com/([%w_.%-]+/[%w_.%-]+)/(issues)/(%d+)"
local PR_URL = "https://github%.com/([%w_.%-]+/[%w_.%-]+)/(pull)/(%d+)"
local QUALIFIED = "([%w_.%-]+/[%w_.%-]+)#(%d+)"

local function parse_url(url)
  -- Only complete issue/PR paths are evidence; a numeric prefix is not a reference.
  local path = url:match("^[^?#]+") or url
  local repo, kind, number = path:match("^" .. URL .. "$")
  if not repo then
    repo, kind, number = path:match("^" .. PR_URL .. "$")
  end
  return repo, kind, number
end

local function add(refs, repo, number, url, explicit)
  refs[number] = refs[number] or {}
  local key = repo:lower()
  local old = refs[number][key]
  if not old or explicit then
    refs[number][key] = { url = url, repo = repo }
  end
end

local function collect(text, refs)
  -- Shorthand uses GitHub's /issues route, which also redirects PR numbers. An explicit
  -- /pull URL takes precedence, so no issue-vs-PR guess is made from nearby prose.
  for repo, number in text:gmatch(QUALIFIED) do
    add(refs, repo, number, "https://github.com/" .. repo .. "/issues/" .. number, false)
  end
  for url in text:gmatch("https://github%.com/[^%s<>%)%]`]+") do
    local repo, _, number = parse_url(url:gsub("[.,;]+$", ""))
    if repo then
      add(refs, repo, number, url:gsub("[.,;]+$", ""), true)
    end
  end
end

function M.build(conversation, previous)
  local refs, urls = {}, {}
  for _, message in ipairs(conversation or {}) do
    local content = message.content or ""
    collect(content, refs)
    for url in content:gmatch("https?://[^%s<>%)%]`]+") do
      urls[url:gsub("[.,;]+$", "")] = true
    end
  end
  -- Existing links are user-editable. Keep their destinations over stale transcript URLs,
  -- but do not mistake a mismatched label/URL for a correction of the labelled number.
  local saved = {}
  for label, url in (previous or ""):gmatch("%[([^%]]+)%]%(([^%)]+)%)") do
    local repo, _, number = parse_url(url)
    local labelled = label:match("#(%d+)$")
    local labelled_repo = label:match("^" .. QUALIFIED .. "$")
    local external_number = url:match("/(%d+)$") or url:match("/(%d+)[?#]")
    if labelled and external_number == labelled then
      urls[url] = true
    end
    if repo and labelled == number and (not labelled_repo or labelled_repo:lower() == repo:lower()) then
      add(saved, repo, labelled, url, true)
    end
  end
  return { candidates = refs, saved = saved, urls = urls }
end

local function resolve(refs, label)
  local repo, number = label:match("^" .. QUALIFIED .. "$")
  number = number or label:match("#(%d+)$")
  local candidates = number and refs.candidates[number]
  local saved = number and refs.saved[number]
  if not candidates and not saved then
    return nil
  end
  if repo then
    return (saved and saved[repo:lower()]) or (candidates and candidates[repo:lower()])
  end
  local only
  for _, candidate in pairs(saved or candidates) do
    if only then
      return nil -- Same number in several repositories: keep a bare number.
    end
    only = candidate
  end
  return only
end

local function render(refs, label)
  local ref = resolve(refs, label)
  return ref and ("[" .. label .. "](" .. ref.url .. ")") or label
end

function M.instruction(refs)
  local links = {}
  local combined = vim.deepcopy(refs.candidates)
  for number, candidates in pairs(refs.saved) do
    combined[number] = combined[number] or {}
    for repo, ref in pairs(candidates) do
      combined[number][repo] = ref
    end
  end
  for number, candidates in pairs(combined) do
    for _, ref in pairs(candidates) do
      links[#links + 1] = "- [" .. ref.repo .. "#" .. number .. "](" .. ref.url .. ")"
    end
  end
  table.sort(links)
  return "cwd のリポジトリから番号の所属を推測してはいけない。"
    .. "以下の参照表だけをリンクの根拠にする。所属不明・曖昧な番号は素の #NNN のまま残す。"
    .. "ラベルと URL の番号を一致させ、issue と PR は別々の行に書く。\n"
    .. table.concat(links, "\n")
end

local function normalize_line(line, refs)
  local held, extra = {}, {}
  local function hold(text)
    held[#held + 1] = text
    return "\001" .. #held .. "\002"
  end
  line = line:gsub("(`+)(.-)%1", function(marker, body)
    return hold(marker .. body .. marker)
  end)
  line = line:gsub("%[([^%]]+)%]%(([^%)]+)%)", function(label, url)
    local _, _, target = parse_url(url)
    local labelled = label:match("#(%d+)$")
    local external_number = url:match("/(%d+)$") or url:match("/(%d+)[?#]")
    if
      labelled
      and not target
      and not url:match("^https://github%.com/")
      and refs.urls[url]
      and external_number == labelled
    then
      return hold("[" .. label .. "](" .. url .. ")")
    end
    if labelled then
      if target and target ~= labelled and resolve(refs, "#" .. target) then
        extra[#extra + 1] = render(refs, "#" .. target)
      end
      return hold(render(refs, label))
    elseif target then
      -- A descriptive label still must not point to an invented repository.
      local ref = resolve(refs, "#" .. target)
      return hold(ref and ("[" .. label .. "](" .. ref.url .. ")") or label)
    end
    return hold("[" .. label .. "](" .. url .. ")")
  end)
  line = line:gsub("https://github%.com/[^%s<>%)%]`]+", function(url)
    local repo, _, number = parse_url(url)
    if repo then
      local label = resolve(refs, repo .. "#" .. number) and (repo .. "#" .. number) or ("#" .. number)
      return hold(render(refs, label))
    end
    return hold(url)
  end)
  line = line:gsub(QUALIFIED, function(repo, number)
    return hold(render(refs, repo .. "#" .. number))
  end)
  line = line:gsub("#%d+", function(label)
    return hold(render(refs, label))
  end)
  line = line:gsub("\001(%d+)\002", function(index)
    return held[tonumber(index)]
  end)
  local lines = { line }
  for _, ref in ipairs(extra) do
    lines[#lines + 1] = "- " .. ref
  end
  return table.concat(lines, "\n")
end

function M.normalize(summary, refs)
  local lines = {}
  local Fence = require("vibing.core.utils.markdown_fence")
  local state
  for _, line in ipairs(vim.split(summary, "\n", { plain = true })) do
    local inside = state ~= nil
    state = Fence.scan({ line }, state)
    lines[#lines + 1] = (inside or state) and line or normalize_line(line, refs)
  end
  local result = table.concat(lines, "\n")
  local missing = {}
  for number, candidates in pairs(refs.saved) do
    for _, ref in pairs(candidates) do
      if not result:find("(" .. ref.url .. ")", 1, true) then
        missing[#missing + 1] = "- [" .. ref.repo .. "#" .. number .. "](" .. ref.url .. ")"
      end
    end
  end
  if #missing > 0 then
    table.sort(missing)
    local output = vim.split(result, "\n", { plain = true })
    local related, insert_at
    local fence
    for i, line in ipairs(output) do
      local inside = fence ~= nil
      fence = Fence.scan({ line }, fence)
      if not inside and not fence then
        if line:match("^### 🔗 関連%s*$") then
          related = true
        elseif related and line:match("^###?%s") then
          insert_at = i
          break
        end
      end
    end
    if not related then
      vim.list_extend(output, { "", "### 🔗 関連", "" })
    end
    if insert_at then
      table.insert(output, insert_at, "")
    end
    insert_at = insert_at or (#output + 1)
    for i, link in ipairs(missing) do
      table.insert(output, insert_at + i - 1, link)
    end
    result = table.concat(output, "\n")
  end
  return result
end

return M
