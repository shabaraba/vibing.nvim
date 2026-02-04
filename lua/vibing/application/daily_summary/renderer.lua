---@class Vibing.Application.DailySummaryRenderer

local M = {}

---@param content string
---@return table|nil parsed
---@return string|nil error
function M.parse_json_response(content)
  -- Extract JSON from response (may have markdown code blocks)
  local json_str = content:match("```json%s*(.-)%s*```")
  if not json_str then
    -- Try to find raw JSON object
    json_str = content:match("%s*(%{.+%})%s*$")
  end
  if not json_str then
    json_str = content
  end

  local ok, parsed = pcall(vim.fn.json_decode, json_str)
  if not ok then
    return nil, "Failed to parse JSON: " .. tostring(parsed)
  end

  if type(parsed) ~= "table" or not parsed.projects then
    return nil, "Invalid JSON structure: missing 'projects' array"
  end

  return parsed, nil
end

---@param items string[]
---@param prefix? string
---@return string[]
local function render_list(items, prefix)
  prefix = prefix or "- "
  local lines = {}
  for _, item in ipairs(items or {}) do
    if item and item ~= "" then
      table.insert(lines, prefix .. item)
    end
  end
  return lines
end

---@param challenges table[]
---@return string[]
local function render_challenges(challenges)
  local lines = {}
  for _, c in ipairs(challenges or {}) do
    if c.problem and c.problem ~= "" then
      table.insert(lines, "- **Problem:** " .. c.problem)
      if c.solution and c.solution ~= "" then
        table.insert(lines, "  - **Solution:** " .. c.solution)
      end
      if c.root_cause and c.root_cause ~= "" then
        table.insert(lines, "  - **Root Cause:** " .. c.root_cause)
      end
    end
  end
  return lines
end

---@param project table
---@return string[]
local function render_project(project)
  local lines = {}

  table.insert(lines, "## " .. (project.name or "Unknown Project"))
  table.insert(lines, "")

  -- What I Did
  local did_items = render_list(project.what_i_did)
  if #did_items > 0 then
    table.insert(lines, "### What I Did")
    table.insert(lines, "")
    vim.list_extend(lines, did_items)
    table.insert(lines, "")
  end

  -- What I Learned
  local learned_items = render_list(project.what_i_learned)
  if #learned_items > 0 then
    table.insert(lines, "### What I Learned")
    table.insert(lines, "")
    vim.list_extend(lines, learned_items)
    table.insert(lines, "")
  end

  -- Challenges & Solutions
  local challenge_items = render_challenges(project.challenges)
  if #challenge_items > 0 then
    table.insert(lines, "### Challenges & Solutions")
    table.insert(lines, "")
    vim.list_extend(lines, challenge_items)
    table.insert(lines, "")
  end

  -- Next Actions
  local next_items = render_list(project.next_actions, "- [ ] ")
  if #next_items > 0 then
    table.insert(lines, "### Next Actions")
    table.insert(lines, "")
    vim.list_extend(lines, next_items)
    table.insert(lines, "")
  end

  -- Notes
  local note_items = render_list(project.notes)
  if #note_items > 0 then
    table.insert(lines, "### Notes")
    table.insert(lines, "")
    vim.list_extend(lines, note_items)
    table.insert(lines, "")
  end

  return lines
end

---@param data table
---@return string
function M.render_markdown(data)
  local lines = {}

  for i, project in ipairs(data.projects or {}) do
    if i > 1 then
      table.insert(lines, "---")
      table.insert(lines, "")
    end
    vim.list_extend(lines, render_project(project))
  end

  return table.concat(lines, "\n")
end

---@param content string
---@return string rendered
---@return string|nil error
function M.process_response(content)
  local data, err = M.parse_json_response(content)
  if err then
    return content, err
  end

  return M.render_markdown(data), nil
end

return M
