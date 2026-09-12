---@class Vibing.Application.JobManager
---Long-running processes owned by Neovim rather than by a short-lived AI CLI process.
--- @module vibing.application.job.manager
local M = {}

local uv = vim.uv or vim.loop
local Fs = require("vibing.core.utils.fs")
local Git = require("vibing.core.utils.git")
local PathSanitizer = require("vibing.domain.security.path_sanitizer")
local Notify = require("vibing.core.utils.notify")

local MAX_TAIL_BYTES = 64 * 1024
local NOTICE_TAIL_LINES = 20
local MAX_WAIT_MS = 25000

---@class Vibing.BackgroundJob
---@field id string
---@field name string
---@field command string[]
---@field cwd string
---@field status "starting"|"running"|"exited"|"stopped"|"failed_to_start"
---@field notify "always"|"on_failure"|"never"|"passive"
---@field readiness "not_requested"|"pending"|"ready"|"timed_out"|"failed"|"exited"
---@field chat_bufnr number
---@field started_at string
---@field started_hrtime number
---@field log_path string
---@field metadata_path string
---@field tail string
---@field handle table?
---@field pid number?
---@field exit_code number?
---@field signal number?
---@field finished_at string?
---@field duration_ms number?
---@field stop_requested boolean?
---@field suppress_notification boolean?
---@field log_fd number?
---@field ready_pattern string?
---@field ready_at string?
---@field ready_timer table?

---@type table<string, Vibing.BackgroundJob>
local jobs = {}
local next_id = 0
local shutting_down = false

local function now()
  return os.date("%Y-%m-%dT%H:%M:%S") --[[@as string]]
end

---@param job Vibing.BackgroundJob
---@return table
local function snapshot(job)
  return {
    id = job.id,
    name = job.name,
    command = vim.deepcopy(job.command),
    cwd = job.cwd,
    status = job.status,
    pid = job.pid,
    notify = job.notify,
    readiness = job.readiness,
    ready_at = job.ready_at,
    started_at = job.started_at,
    finished_at = job.finished_at,
    duration_ms = job.duration_ms,
    exit_code = job.exit_code,
    signal = job.signal,
    log_path = job.log_path,
  }
end

---@param job Vibing.BackgroundJob
local function persist(job)
  local data = snapshot(job)
  local ok, encoded = pcall(vim.json.encode, data)
  if not ok then
    Notify.warn(string.format("Could not encode background job %s metadata: %s", job.id, encoded), "Jobs")
    return
  end
  local write_ok, err = pcall(vim.fn.writefile, { encoded }, job.metadata_path)
  if not write_ok then
    Notify.warn(string.format("Could not persist background job %s: %s", job.id, err), "Jobs")
  end
end

---@param value any
---@param label string
local function require_non_empty_string(value, label)
  if type(value) ~= "string" or vim.trim(value) == "" then
    error(label .. " must be a non-empty string")
  end
  if value:find("[\r\n]") then
    error(label .. " must not contain line breaks")
  end
end

---@param command any
---@return string[]
local function validate_command(command)
  if type(command) ~= "table" or #command == 0 then
    error("command must be a non-empty argv array")
  end
  local result = {}
  for index, value in ipairs(command) do
    require_non_empty_string(value, string.format("command[%d]", index))
    table.insert(result, value)
  end
  return result
end

---@param requested_cwd any
---@param base_cwd any
---@return string cwd
---@return string root
local function resolve_cwd(requested_cwd, base_cwd)
  require_non_empty_string(base_cwd, "base_cwd")
  local base_root = Git.get_root(base_cwd)
  if not base_root then
    error("Background jobs require the calling chat to run inside a Git repository")
  end

  local cwd, err = PathSanitizer.normalize(requested_cwd or base_cwd)
  if not cwd then
    error("Could not resolve cwd: " .. tostring(err))
  end
  if not PathSanitizer.is_within_root(base_root, cwd) then
    error(string.format("cwd must stay inside the calling chat's Git root (%s)", base_root))
  end
  if vim.fn.isdirectory(cwd) == 0 then
    error("cwd does not exist or is not a directory: " .. cwd)
  end
  return cwd, base_root
end

local function allocate_id()
  next_id = next_id + 1
  return string.format("job-%d-%d-%d", os.time(), vim.fn.getpid(), next_id)
end

---@param value string
---@param count number
---@return string
local function last_lines(value, count)
  if value == "" then
    return ""
  end
  local lines = vim.split(value, "\n", { plain = true })
  while #lines > 0 and lines[#lines] == "" do
    table.remove(lines)
  end
  local first = math.max(1, #lines - count + 1)
  return table.concat(vim.list_slice(lines, first, #lines), "\n")
end

---@param job Vibing.BackgroundJob
---@param data string?
local function append_output(job, data)
  if not data or data == "" then
    return
  end
  job.tail = job.tail .. data
  if #job.tail > MAX_TAIL_BYTES then
    job.tail = job.tail:sub(#job.tail - MAX_TAIL_BYTES + 1)
  end
  if job.log_fd then
    local ok, written, err = pcall(uv.fs_write, job.log_fd, data, -1)
    if not ok or not written then
      local detail = ok and err or written
      vim.schedule(function()
        Notify.warn(string.format("Could not write background job %s log: %s", job.id, detail), "Jobs")
      end)
      pcall(uv.fs_close, job.log_fd)
      job.log_fd = nil
    end
  end
  if job.readiness == "pending" and job.ready_pattern and job.tail:find(job.ready_pattern, 1, true) then
    job.readiness = "ready"
    job.ready_at = now()
    if job.ready_timer then
      job.ready_timer:stop()
      job.ready_timer:close()
      job.ready_timer = nil
    end
    vim.schedule(function()
      persist(job)
    end)
  end
end

---@param job Vibing.BackgroundJob
---@return boolean
local function should_notify(job)
  if shutting_down or job.suppress_notification or job.notify == "never" or job.notify == "passive" then
    return false
  end
  if job.notify == "on_failure" then
    return job.status == "failed_to_start"
      or (job.status == "exited" and ((job.exit_code or 0) ~= 0 or (job.signal or 0) ~= 0))
  end
  return true
end

---@param value string
---@return string
local function indent(value)
  return value:gsub("([^\n]+)", "    %1")
end

---@param job Vibing.BackgroundJob
local function notify_chat(job)
  local passive = job.notify == "passive"
  if passive and (shutting_down or job.suppress_notification) then
    return
  end
  if not passive and not should_notify(job) then
    return
  end
  if not vim.api.nvim_buf_is_valid(job.chat_bufnr) then
    Notify.warn(string.format("Background job %s finished, but its source chat no longer exists", job.id), "Jobs")
    return
  end

  local outcome
  if job.status == "failed_to_start" then
    outcome = "failed to start"
  elseif job.status == "stopped" then
    outcome = "was stopped"
  else
    outcome = string.format("exited with code %s and signal %s", tostring(job.exit_code), tostring(job.signal))
  end

  local lines = {
    string.format("Background job `%s` (%s) %s.", job.name, job.id, outcome),
    "",
    string.format("- Duration: %dms", job.duration_ms or 0),
    string.format("- Log: `%s`", job.log_path),
  }
  local tail = last_lines(job.tail, NOTICE_TAIL_LINES)
  if tail ~= "" then
    vim.list_extend(lines, { "", "Last output:", "", indent(tail) })
  end
  table.insert(lines, "")
  table.insert(lines, "Inspect the result and continue the task that started this job.")

  local Queue = require("vibing.application.chat.message_queue")
  local ok, err = Queue.enqueue_notice(job.chat_bufnr, table.concat(lines, "\n"), passive)
  if not ok then
    Notify.warn(string.format("Could not notify chat about background job %s: %s", job.id, err), "Jobs")
    return
  end
  Queue.flush(job.chat_bufnr)
end

---@param job Vibing.BackgroundJob
---@param result table
local function finish(job, result)
  if job.status ~= "running" and job.status ~= "starting" then
    return
  end
  job.exit_code = result.code
  job.signal = result.signal
  job.finished_at = now()
  job.duration_ms = math.floor((uv.hrtime() - job.started_hrtime) / 1000000)
  job.status = job.stop_requested and "stopped" or "exited"
  if job.readiness == "pending" then
    job.readiness = "exited"
  end
  if job.ready_timer then
    job.ready_timer:stop()
    job.ready_timer:close()
    job.ready_timer = nil
  end
  if job.log_fd then
    pcall(uv.fs_close, job.log_fd)
    job.log_fd = nil
  end
  persist(job)
  notify_chat(job)
end

---@param params {command: string[], name?: string, cwd?: string, base_cwd: string, from_bufnr: number, notify?: string, env?: table<string, string>, ready_pattern?: string, ready_timeout_ms?: number}
---@return table
function M.start(params)
  params = params or {}
  local command = validate_command(params.command)
  local cwd, root = resolve_cwd(params.cwd, params.base_cwd)
  local name = params.name or command[1]
  require_non_empty_string(name, "name")
  if #name > 100 then
    error("name must be at most 100 characters")
  end
  local notification = params.notify or "always"
  if notification ~= "always" and notification ~= "on_failure" and notification ~= "never" and notification ~= "passive" then
    error("notify must be one of: always, on_failure, never, passive")
  end
  if type(params.from_bufnr) ~= "number" then
    error("from_bufnr must name the chat starting this job")
  end
  local env = params.env
  if env ~= nil then
    if type(env) ~= "table" then
      error("env must be an object of string values")
    end
    for key, value in pairs(env) do
      require_non_empty_string(key, "env key")
      if type(value) ~= "string" or value:find("%z") then
        error("env values must be strings without NUL bytes")
      end
    end
  end
  local ready_pattern = params.ready_pattern
  if ready_pattern ~= nil then
    require_non_empty_string(ready_pattern, "ready_pattern")
    if #ready_pattern > 500 then
      error("ready_pattern must be at most 500 characters")
    end
  end
  local ready_timeout_ms = params.ready_timeout_ms or 30000
  if
    type(ready_timeout_ms) ~= "number"
    or ready_timeout_ms < 1
    or ready_timeout_ms > 3600000
    or ready_timeout_ms ~= math.floor(ready_timeout_ms)
  then
    error("ready_timeout_ms must be an integer from 1 to 3600000")
  end

  local id = allocate_id()
  local dir = root .. "/.vibing/jobs"
  Fs.ensure_dir(dir)
  local job = {
    id = id,
    name = name,
    command = command,
    cwd = cwd,
    status = "starting",
    notify = notification,
    readiness = ready_pattern and "pending" or "not_requested",
    ready_pattern = ready_pattern,
    chat_bufnr = params.from_bufnr,
    started_at = now(),
    started_hrtime = uv.hrtime(),
    log_path = dir .. "/" .. id .. ".log",
    metadata_path = dir .. "/" .. id .. ".json",
    tail = "",
  }
  jobs[id] = job

  local fd, open_err = uv.fs_open(job.log_path, "w", 420)
  if not fd then
    jobs[id] = nil
    error("Could not open background job log: " .. tostring(open_err))
  end
  job.log_fd = fd
  persist(job)

  local ok, handle_or_err = pcall(vim.system, command, {
    cwd = cwd,
    env = env,
    text = true,
    stdout = function(err, data)
      if err then
        append_output(job, "[stdout error] " .. tostring(err) .. "\n")
      end
      append_output(job, data)
    end,
    stderr = function(err, data)
      if err then
        append_output(job, "[stderr error] " .. tostring(err) .. "\n")
      end
      append_output(job, data)
    end,
  }, function(result)
    vim.schedule(function()
      finish(job, result)
    end)
  end)

  if not ok then
    append_output(job, tostring(handle_or_err) .. "\n")
    job.status = "failed_to_start"
    if job.readiness == "pending" then
      job.readiness = "failed"
    end
    job.finished_at = now()
    job.duration_ms = math.floor((uv.hrtime() - job.started_hrtime) / 1000000)
    if job.log_fd then
      pcall(uv.fs_close, job.log_fd)
      job.log_fd = nil
    end
    persist(job)
    notify_chat(job)
    error("Could not start background job: " .. tostring(handle_or_err))
  end

  job.handle = handle_or_err
  job.pid = handle_or_err.pid
  job.status = "running"
  persist(job)
  if ready_pattern and job.readiness == "pending" then
    job.ready_timer = uv.new_timer()
    job.ready_timer:start(ready_timeout_ms, 0, function()
      vim.schedule(function()
        if job.readiness == "pending" then
          job.readiness = "timed_out"
          if job.ready_timer then
            job.ready_timer:close()
            job.ready_timer = nil
          end
          persist(job)
        end
      end)
    end)
  end
  return snapshot(job)
end

---@param id any
---@return Vibing.BackgroundJob
local function require_job(id)
  require_non_empty_string(id, "job_id")
  local job = jobs[id]
  if not job then
    error("Unknown background job: " .. id)
  end
  return job
end

---@param params {job_id: string, tail_lines?: number}
---@return table
function M.status(params)
  params = params or {}
  local job = require_job(params.job_id)
  local count = params.tail_lines or 20
  if type(count) ~= "number" or count < 0 or count > 200 or count ~= math.floor(count) then
    error("tail_lines must be an integer from 0 to 200")
  end
  local result = snapshot(job)
  result.output_tail = count > 0 and last_lines(job.tail, count) or ""
  return result
end

---@return table
function M.list()
  local result = {}
  for _, job in pairs(jobs) do
    table.insert(result, snapshot(job))
  end
  table.sort(result, function(a, b)
    return a.id < b.id
  end)
  return { jobs = result }
end

---@param params {job_id: string}
---@return table
function M.stop(params)
  params = params or {}
  local job = require_job(params.job_id)
  if job.status ~= "running" and job.status ~= "starting" then
    return snapshot(job)
  end
  if job.stop_requested then
    return snapshot(job)
  end
  job.stop_requested = true
  local ok, err = pcall(function()
    job.handle:kill(15)
  end)
  if not ok then
    job.stop_requested = false
    error("Could not stop background job: " .. tostring(err))
  end
  return snapshot(job)
end

---@param params {job_id: string, timeout_ms?: number, tail_lines?: number, until?: "exit"|"ready"}
---@return table
function M.wait(params)
  params = params or {}
  local timeout = params.timeout_ms or MAX_WAIT_MS
  if type(timeout) ~= "number" or timeout < 0 or timeout > MAX_WAIT_MS or timeout ~= math.floor(timeout) then
    error(string.format("timeout_ms must be an integer from 0 to %d", MAX_WAIT_MS))
  end
  local job = require_job(params.job_id)
  local until_event = params["until"] or "exit"
  if until_event ~= "exit" and until_event ~= "ready" then
    error("until must be one of: exit, ready")
  end
  local function reached()
    local exited = job.status ~= "running" and job.status ~= "starting"
    return exited or (until_event == "ready" and job.readiness ~= "pending")
  end
  local finished = reached()
    or vim.wait(timeout, function()
      return reached()
    end, 20)
  local result = M.status({ job_id = job.id, tail_lines = params.tail_lines })
  result.timed_out = not finished
  return result
end

function M.shutdown()
  shutting_down = true
  for _, job in pairs(jobs) do
    if job.status == "running" or job.status == "starting" then
      job.suppress_notification = true
      job.stop_requested = true
      pcall(function()
        job.handle:kill(15)
      end)
    end
  end
end

---Test seam: forget all process metadata after each isolated spec.
function M._reset()
  for _, job in pairs(jobs) do
    if job.ready_timer then
      pcall(job.ready_timer.stop, job.ready_timer)
      pcall(job.ready_timer.close, job.ready_timer)
    end
    if job.log_fd then
      pcall(uv.fs_close, job.log_fd)
    end
  end
  jobs = {}
  next_id = 0
  shutting_down = false
end

return M
