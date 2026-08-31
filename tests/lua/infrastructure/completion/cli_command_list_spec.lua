-- The probe talks an undocumented control protocol to the real `claude` binary, so what these
-- specs pin is the half that can go wrong silently: that the request actually goes out, that the
-- flags a chat gets are repeated on it, and that a response we cannot read produces no
-- completions rather than a half-parsed list.
--
-- A fake `claude` is put on PATH before the module is required, so `binary_resolver`'s
-- process-wide cache resolves to it. PlenaryBustedDirectory runs one Neovim per spec file, so
-- nothing else in the suite sees this PATH.

local ROOT = vim.fn.tempname()
vim.fn.mkdir(ROOT, "p")

local ARGV_LOG = ROOT .. "/argv"

---Write an executable fake `claude` that records its argv, waits for one stdin line, then
---prints `stdout_lines`.
---@param stdout_lines string[]
local function write_fake_claude(stdout_lines)
  local script = { "#!/bin/sh", 'printf "%s\\n" "$@" > ' .. vim.fn.shellescape(ARGV_LOG), "read -r _line" }
  for _, line in ipairs(stdout_lines) do
    table.insert(script, "printf '%s\\n' " .. vim.fn.shellescape(line))
  end

  local path = ROOT .. "/claude"
  vim.fn.writefile(script, path)
  vim.fn.setfperm(path, "rwxr-xr-x")
end

vim.env.PATH = ROOT .. ":" .. vim.env.PATH

local CliCommandList = require("vibing.infrastructure.completion.cli_command_list")

local SUCCESS = table.concat({
  '{"type":"control_response","response":{"subtype":"success",',
  '"request_id":"vibing-list-commands","response":{"commands":[',
  '{"name":"design","description":"Grant or revoke Claude agent access"}]}}}',
})

---Run the probe and block until it answers.
---@param opts table?
---@return Vibing.CliCommand[]?
local function fetch(opts)
  local answered, result = false, nil
  local started = CliCommandList.fetch(
    vim.tbl_extend("keep", opts or {}, {
      cwd = ROOT,
      config = { agent = { setting_sources = { "user" } } },
    }),
    function(commands)
      result = commands
      answered = true
    end
  )
  assert.is_true(started)
  assert.is_true(vim.wait(5000, function()
    return answered
  end, 20))
  return result
end

describe("cli_command_list", function()
  after_each(function()
    vim.fn.delete(ARGV_LOG)
  end)

  it("returns the commands the CLI reports", function()
    write_fake_claude({ SUCCESS })

    local commands = fetch()

    assert.are.equal(1, #commands)
    assert.are.equal("design", commands[1].name)
  end)

  it("repeats the flags a chat gets, so the two see the same commands", function()
    write_fake_claude({ SUCCESS })

    fetch({ plugin_dirs = { "/tmp/plugin-a", "/tmp/plugin-b" } })

    local argv = table.concat(vim.fn.readfile(ARGV_LOG), " ")
    assert.is_truthy(argv:find("--setting-sources user", 1, true))
    assert.is_truthy(argv:find("--plugin-dir /tmp/plugin-a", 1, true))
    assert.is_truthy(argv:find("--plugin-dir /tmp/plugin-b", 1, true))
    -- Killing the process the moment it answers is what makes MCP servers pointless to start.
    assert.is_truthy(argv:find("--strict-mcp-config", 1, true))
  end)

  it("still finds the answer behind a line the CLI printed first", function()
    write_fake_claude({ "some unrelated notice", SUCCESS })

    local commands = fetch()

    assert.are.equal("design", commands[1].name)
  end)

  it("returns nil for an error response rather than an empty list", function()
    -- nil means "ask again"; an empty list would be cached as "this project has no commands".
    write_fake_claude({
      '{"type":"control_response","response":{"subtype":"error",'
        .. '"request_id":"vibing-list-commands","error":"Unsupported control request subtype"}}',
    })

    assert.is_nil(fetch())
  end)

  it("returns nil when the response is not JSON at all", function()
    write_fake_claude({ "not json" })

    assert.is_nil(fetch())
  end)
end)
