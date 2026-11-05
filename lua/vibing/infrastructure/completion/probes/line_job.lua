--- A short-lived CLI process that speaks one JSON object per line, asked a single question.
---
--- Every command probe is this shape: spawn, write a request, wait for one answer, kill. They
--- differ only in what is written and which line is the answer, so the process handling lives here
--- once -- the split-line reassembly, the "answered exactly once" guarantee and the deadline.
--- @module vibing.infrastructure.completion.probes.line_job

local M = {}

--- Long enough for a cold start of a large binary on a busy machine; short enough that a CLI which
--- never answers does not pin the job for the rest of the session.
M.DEFAULT_TIMEOUT_MS = 15000

--- @class Vibing.LineJobOpts
--- @field argv string[]
--- @field cwd string
--- @field timeout_ms integer?
--- @field start fun(send: fun(message: table)) writes the first request
--- @field on_message fun(message: table, send: fun(message: table), finish: fun(result: any))
---   called for every line that decodes to a table; `finish` ends the job with the answer

--- @param opts Vibing.LineJobOpts
--- @param callback fun(result: any) called once; nil when the process ended without an answer
--- @return boolean started false when the job never launched, so the caller can retry later
function M.run(opts, callback)
  local answered = false
  local job_id = nil
  local pending = { "" }

  local function finish(result)
    if answered then
      return
    end
    answered = true
    if job_id then
      pcall(vim.fn.jobstop, job_id)
    end
    callback(result)
  end

  local function send(message)
    if job_id then
      vim.fn.chansend(job_id, vim.json.encode(message) .. "\n")
    end
  end

  local function consume(line)
    local ok, decoded = pcall(vim.json.decode, line)
    if ok and type(decoded) == "table" then
      opts.on_message(decoded, send, finish)
    end
  end

  job_id = vim.fn.jobstart(opts.argv, {
    cwd = opts.cwd,
    on_stdout = function(_, data)
      if answered or type(data) ~= "table" or #data == 0 then
        return
      end
      -- data[1] continues the partial line left by the previous call; an answer of tens of KB
      -- always arrives split across several of them.
      pending[#pending] = pending[#pending] .. (data[1] or "")
      for i = 2, #data do
        table.insert(pending, data[i])
      end

      -- Every complete line is tried rather than only the first: anything the CLI decides to
      -- print ahead of the answer would otherwise be read as the answer and discard it.
      while #pending > 1 and not answered do
        consume(table.remove(pending, 1))
      end
    end,
    on_exit = vim.schedule_wrap(function()
      finish(nil)
    end),
  })

  if type(job_id) ~= "number" or job_id <= 0 then
    job_id = nil
    return false
  end

  opts.start(send)

  vim.defer_fn(function()
    if not answered and job_id then
      pcall(vim.fn.jobstop, job_id)
    end
  end, opts.timeout_ms or M.DEFAULT_TIMEOUT_MS)

  return true
end

return M
