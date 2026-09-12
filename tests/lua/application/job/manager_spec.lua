local Git = require("vibing.core.utils.git")

describe("Neovim-owned background jobs", function()
  local Manager
  local original_system
  local original_get_root
  local original_queue
  local tmp_root
  local chat_bufnr
  local spawn
  local spawns
  local notices
  local flushes

  before_each(function()
    tmp_root = vim.fn.resolve(vim.fn.tempname())
    vim.fn.mkdir(tmp_root, "p")
    chat_bufnr = vim.api.nvim_create_buf(false, true)
    notices, flushes = {}, 0

    original_system = vim.system
    original_get_root = Git.get_root
    original_queue = package.loaded["vibing.application.chat.message_queue"]
    Git.get_root = function()
      return tmp_root
    end
    package.loaded["vibing.application.chat.message_queue"] = {
      enqueue_notice = function(bufnr, body, passive)
        table.insert(notices, { bufnr = bufnr, body = body, passive = passive })
        return true
      end,
      flush = function(bufnr)
        flushes = flushes + 1
        return bufnr == chat_bufnr
      end,
    }

    spawn, spawns = {}, {}
    vim.system = function(command, opts, on_exit)
      spawn = { command = command, opts = opts, on_exit = on_exit, kills = {} }
      table.insert(spawns, spawn)
      return {
        pid = 4242,
        kill = function(_, signal)
          table.insert(spawn.kills, signal)
        end,
      }
    end

    package.loaded["vibing.application.job.manager"] = nil
    Manager = require("vibing.application.job.manager")
  end)

  after_each(function()
    if Manager then
      Manager._reset()
    end
    vim.system = original_system
    Git.get_root = original_get_root
    package.loaded["vibing.application.chat.message_queue"] = original_queue
    package.loaded["vibing.application.job.manager"] = nil
    if chat_bufnr and vim.api.nvim_buf_is_valid(chat_bufnr) then
      vim.api.nvim_buf_delete(chat_bufnr, { force = true })
    end
    if tmp_root then
      vim.fn.delete(tmp_root, "rf")
    end
  end)

  local function start(overrides)
    local params = {
      command = { "sh", "-c", "printf done" },
      name = "build",
      cwd = tmp_root,
      base_cwd = tmp_root,
      from_bufnr = chat_bufnr,
      notify = "always",
    }
    for key, value in pairs(overrides or {}) do
      params[key] = value
    end
    return Manager.start(params)
  end

  it("owns the process, captures output, persists metadata, and wakes the source chat", function()
    local started = start()

    assert.equals("running", started.status)
    assert.same({ "sh", "-c", "printf done" }, spawn.command)
    assert.equals(tmp_root, spawn.opts.cwd)
    assert.equals(4242, started.pid)

    spawn.opts.stdout(nil, "first line\nlast line\n")
    spawn.on_exit({ code = 0, signal = 0 })
    assert.is_true(vim.wait(1000, function()
      return #notices == 1
    end))

    local status = Manager.status({ job_id = started.id, tail_lines = 1 })
    assert.equals("exited", status.status)
    assert.equals(0, status.exit_code)
    assert.equals("last line", status.output_tail)
    assert.equals(chat_bufnr, notices[1].bufnr)
    assert.is_truthy(notices[1].body:find("exited with code 0", 1, true))
    assert.is_truthy(notices[1].body:find("Inspect the result and continue", 1, true))
    assert.equals(1, flushes)
    assert.equals(1, vim.fn.filereadable(started.log_path))
    assert.equals(1, vim.fn.filereadable((started.log_path:gsub("%.log$", ".json"))))
  end)

  it("supports on-failure notifications without waking for success", function()
    local success = start({ notify = "on_failure" })
    spawn.on_exit({ code = 0, signal = 0 })
    assert.is_true(vim.wait(1000, function()
      return Manager.status({ job_id = success.id }).status == "exited"
    end))
    assert.equals(0, #notices)

    local failed = start({ notify = "on_failure", name = "failing build" })
    spawn.on_exit({ code = 2, signal = 0 })
    assert.is_true(vim.wait(1000, function()
      return #notices == 1
    end))
    assert.is_truthy(notices[1].body:find(failed.id, 1, true))
  end)

  it("passes environment overrides and distinguishes readiness from process existence", function()
    local started = start({
      env = { PORT = "4321" },
      ready_pattern = "server ready",
      ready_timeout_ms = 5000,
      notify = "never",
    })

    assert.same({ PORT = "4321" }, spawn.opts.env)
    assert.equals("pending", started.readiness)
    assert.equals("running", started.status)

    spawn.opts.stdout(nil, "booting\nserver ready on 4321\n")
    assert.is_true(vim.wait(1000, function()
      return Manager.status({ job_id = started.id }).readiness == "ready"
    end))
    local waited = Manager.wait({ job_id = started.id, ["until"] = "ready", timeout_ms = 0 })
    assert.is_false(waited.timed_out)
    assert.equals("running", waited.status)
    spawn.on_exit({ code = 0, signal = 0 })
    assert.is_true(vim.wait(1000, function()
      return Manager.status({ job_id = started.id }).status == "exited"
    end))
  end)

  it("marks a readiness timeout without pretending the still-running process exited", function()
    local started = start({ ready_pattern = "never printed", ready_timeout_ms = 10, notify = "never" })

    assert.is_true(vim.wait(1000, function()
      return Manager.status({ job_id = started.id }).readiness == "timed_out"
    end))
    local status = Manager.status({ job_id = started.id })
    assert.equals("running", status.status)
    assert.equals("timed_out", status.readiness)
    spawn.on_exit({ code = 0, signal = 0 })
    assert.is_true(vim.wait(1000, function()
      return Manager.status({ job_id = started.id }).status == "exited"
    end))
  end)

  it("keeps only a bounded output tail while retaining the full log", function()
    local started = start({ notify = "never" })
    local output = string.rep("x", 70 * 1024)

    spawn.opts.stdout(nil, output)
    local status = Manager.status({ job_id = started.id, tail_lines = 200 })

    assert.is_true(#status.output_tail <= 64 * 1024)
    assert.equals(70 * 1024, vim.fn.getfsize(started.log_path))
    spawn.on_exit({ code = 0, signal = 0 })
    assert.is_true(vim.wait(1000, function()
      return Manager.status({ job_id = started.id }).status == "exited"
    end))
  end)

  it("tracks concurrent jobs independently", function()
    local first = start({ name = "first", notify = "never" })
    local second = start({ name = "second", notify = "never" })

    assert.are_not.equals(first.id, second.id)
    assert.equals(2, #Manager.list().jobs)
    spawns[1].on_exit({ code = 0, signal = 0 })
    spawns[2].on_exit({ code = 3, signal = 0 })
    assert.is_true(vim.wait(1000, function()
      return Manager.status({ job_id = second.id }).status == "exited"
    end))
    assert.equals(0, Manager.status({ job_id = first.id }).exit_code)
    assert.equals(3, Manager.status({ job_id = second.id }).exit_code)
  end)

  it("does not lose an exit callback that arrives before vim.system returns", function()
    vim.system = function(_, _, on_exit)
      on_exit({ code = 0, signal = 0 })
      return { pid = 99, kill = function() end }
    end

    local started = start()

    assert.is_true(vim.wait(1000, function()
      return Manager.status({ job_id = started.id }).status == "exited"
    end))
    assert.equals(1, #notices)
  end)

  it("uses passive completion to append a Notice without waking the LLM", function()
    start({ notify = "passive" })
    spawn.on_exit({ code = 0, signal = 0 })

    assert.is_true(vim.wait(1000, function()
      return #notices == 1
    end))
    assert.is_true(notices[1].passive)
  end)

  it("requests SIGTERM and reports an explicitly stopped job", function()
    local started = start()

    local stopping = Manager.stop({ job_id = started.id })
    assert.equals("running", stopping.status)
    assert.same({ 15 }, spawn.kills)
    Manager.stop({ job_id = started.id })
    assert.same({ 15 }, spawn.kills, "repeated stop must be idempotent")

    spawn.on_exit({ code = 0, signal = 15 })
    assert.is_true(vim.wait(1000, function()
      return #notices == 1
    end))
    assert.equals("stopped", Manager.status({ job_id = started.id }).status)
    assert.is_truthy(notices[1].body:find("was stopped", 1, true))
  end)

  it("rejects a cwd outside the calling chat's repository before spawning", function()
    assert.has_error(function()
      start({ cwd = vim.fn.fnamemodify(tmp_root .. "/../outside", ":p") })
    end, "cwd must stay inside the calling chat's Git root (" .. tmp_root .. ")")
    assert.is_nil(spawn.command)
  end)
end)
