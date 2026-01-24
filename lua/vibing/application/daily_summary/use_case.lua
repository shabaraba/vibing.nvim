---@class Vibing.Application.DailySummaryUseCase

local Collector = require("vibing.application.daily_summary.collector")
local FileManager = require("vibing.presentation.chat.modules.file_manager")
local notify = require("vibing.core.utils.notify")

local M = {}

---@param config table
---@return string
local function get_save_directory(config)
  if config.daily_summary and config.daily_summary.save_dir then
    local save_dir = config.daily_summary.save_dir
    return save_dir:match("/$") and save_dir or (save_dir .. "/")
  end

  local chat_dir = FileManager.get_save_directory(config.chat or {})
  if chat_dir:match("/chat/$") then
    return chat_dir:gsub("/chat/$", "/daily/")
  end
  return chat_dir .. "daily/"
end

---@param messages table[]
---@param date string
---@param config table
---@return string
function M._build_summary_prompt(messages, date, config)
  local language_utils = require("vibing.core.utils.language")
  local lang_code = language_utils.get_language_code(config.language, "chat")

  local lang_instruction = ""
  if lang_code and lang_code ~= "en" then
    local lang_name = language_utils.language_names[lang_code] or lang_code
    lang_instruction = string.format("\n\n**Output language:** Please write the summary in %s.", lang_name)
  end

  local lines = {
    string.format("# Daily Summary Request for %s", date),
    "",
    "Below are conversation pairs from today's development sessions.",
    "Please analyze them and create a daily summary in the following format:",
    "",
    "## Required Output Format",
    "",
    "```markdown",
    "## Done",
    "- (List of completed tasks, implemented features, fixed bugs)",
    "",
    "## Challenges and Solutions",
    "- (Technical challenges encountered and how they were resolved)",
    "",
    "## Remaining Tasks",
    "- (Remaining tasks, TODOs, items to follow up on)",
    "```",
    "",
    "**Important:**",
    "- Be concise but comprehensive",
    "- Group related items together",
    "- Include specific details (file names, function names, etc.) when relevant",
    "- If there are no items for a section, write \"None\"",
    lang_instruction,
    "",
    "---",
    "",
    "# Today's Conversations",
    "",
  }

  for i, msg in ipairs(messages) do
    local assistant_preview = msg.assistant
    if #assistant_preview > 1000 then
      assistant_preview = assistant_preview:sub(1, 1000) .. "\n\n[... truncated for brevity ...]"
    end

    vim.list_extend(lines, {
      string.format("## Conversation %d", i),
      string.format("**Time:** %s", msg.timestamp or "unknown"),
      string.format("**Source:** %s", msg.file),
      "",
      "### User Request:",
      msg.user,
      "",
      "### Assistant Response:",
      assistant_preview,
      "",
      "---",
      "",
    })
  end

  return table.concat(lines, "\n")
end

---@param date string
---@param source_files string[]
---@param total_messages number
---@return string[]
local function generate_frontmatter(date, source_files, total_messages)
  local lines = {
    "---",
    "type: daily-summary",
    string.format("date: %s", date),
    string.format("generated_at: %s", os.date("%Y-%m-%d %H:%M:%S")),
    string.format("total_messages: %d", total_messages),
    string.format("total_files: %d", #source_files),
    "tags:",
    "  - vibing",
    "  - daily-summary",
  }

  if #source_files > 0 then
    table.insert(lines, "source_files:")
    for _, file in ipairs(source_files) do
      local escaped = file:gsub("\\", "\\\\"):gsub('"', '\\"')
      table.insert(lines, string.format('  - "%s"', escaped))
    end
  end

  table.insert(lines, "---")
  table.insert(lines, "")
  return lines
end

---@param date string
---@param content string
---@param source_files string[]
---@param total_messages number
---@param config table
---@param on_complete fun(success: boolean, file_path: string|nil)
function M._save_summary(date, content, source_files, total_messages, config, on_complete)
  local save_dir = get_save_directory(config)
  vim.fn.mkdir(save_dir, "p")

  local file_path = save_dir .. date .. ".md"

  if vim.fn.filereadable(file_path) == 1 then
    local choice = vim.fn.confirm(
      string.format("Summary for %s already exists. Overwrite?", date),
      "&Yes\n&No",
      2
    )
    if choice ~= 1 then
      notify.info("Summary generation cancelled", "Daily Summary")
      on_complete(false, nil)
      return
    end
  end

  local frontmatter = generate_frontmatter(date, source_files, total_messages)
  local output_lines = vim.list_extend(frontmatter, vim.split(content, "\n"))
  local result = vim.fn.writefile(output_lines, file_path)
  if result == -1 then
    notify.error("Failed to write summary file: " .. file_path, "Daily Summary")
    on_complete(false, nil)
    return
  end
  on_complete(true, file_path)
end

---@param date string
---@param include_all boolean
---@param on_complete? fun(success: boolean, file_path: string|nil)
function M.generate_summary(date, include_all, on_complete)
  on_complete = on_complete or function() end

  local config = require("vibing.config").get()
  local adapter = require("vibing").get_adapter()

  if not adapter then
    notify.error("No adapter configured", "Daily Summary")
    on_complete(false, nil)
    return
  end

  notify.info(string.format("Collecting messages for %s...", date), "Daily Summary")
  local result = Collector.collect_all_messages(date, include_all, config)

  if result.total_messages == 0 then
    notify.warn(string.format("No messages found for %s", date), "Daily Summary")
    on_complete(false, nil)
    return
  end

  notify.info(
    string.format("Found %d messages from %d files. Generating summary...", result.total_messages, #result.source_files),
    "Daily Summary"
  )

  local prompt = M._build_summary_prompt(result.messages, date, config)
  local accumulated_content = ""

  adapter:stream(prompt, {
    streaming = true,
    action_type = "daily_summary",
    mode = "code",
    model = config.agent and config.agent.default_model or "sonnet",
  }, function(chunk)
    accumulated_content = accumulated_content .. chunk
  end, function(response)
    vim.schedule(function()
      if response.error then
        notify.error("Summary generation failed: " .. response.error, "Daily Summary")
        on_complete(false, nil)
        return
      end

      local final_content = response.content or accumulated_content
      M._save_summary(date, final_content, result.source_files, result.total_messages, config, function(success, file_path)
        if success and file_path then
          notify.info(string.format("Summary saved: %s", vim.fn.fnamemodify(file_path, ":.")), "Daily Summary")
          vim.cmd("edit " .. vim.fn.fnameescape(file_path))
        end
        on_complete(success, file_path)
      end)
    end)
  end)
end

---@param year number
---@param month number
---@return number
local function days_in_month(year, month)
  local days = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
  if month == 2 then
    local is_leap = (year % 4 == 0 and year % 100 ~= 0) or (year % 400 == 0)
    return is_leap and 29 or 28
  end
  return days[month]
end

---@param date_str string|nil
---@return string|nil validated_date
---@return string|nil error
function M.validate_date(date_str)
  if not date_str or date_str == "" then
    return os.date("%Y-%m-%d"), nil
  end

  local year, month, day = date_str:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
  if not year then
    return nil, "Invalid date format. Use YYYY-MM-DD (e.g., 2025-01-24)"
  end

  year = tonumber(year)
  month = tonumber(month)
  day = tonumber(day)

  if month < 1 or month > 12 then
    return nil, "Invalid month: must be between 01 and 12"
  end

  local max_days = days_in_month(year, month)
  if day < 1 or day > max_days then
    return nil, string.format("Invalid day: %d-%02d has %d days", year, month, max_days)
  end

  return date_str, nil
end

return M
