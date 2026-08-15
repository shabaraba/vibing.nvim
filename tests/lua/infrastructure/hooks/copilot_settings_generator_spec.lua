local CopilotSettingsGenerator = require("vibing.infrastructure.hooks.copilot_settings_generator")
local SettingsGenerator = require("vibing.infrastructure.hooks.settings_generator")

--- Read the generated manifest for a cwd
--- @param cwd string
--- @return table
local function read_manifest(cwd)
  local path = CopilotSettingsGenerator.ensure(cwd) .. "/plugin.json"
  local f = io.open(path, "r")
  assert.is_not_nil(f, "expected " .. path .. " to exist")
  local content = f:read("*a")
  f:close()
  local ok, decoded = pcall(vim.json.decode, content)
  assert.is_true(ok, "expected valid JSON in " .. path)
  return decoded
end

--- @param manifest table
--- @return table the single preToolUse hook entry
local function hook_entry(manifest)
  return manifest.hooks.preToolUse[1]
end

describe("copilot_settings_generator", function()
  local tmp_dir

  before_each(function()
    tmp_dir = vim.fn.tempname()
    vim.fn.mkdir(tmp_dir, "p")
  end)

  after_each(function()
    if tmp_dir then
      vim.fn.delete(tmp_dir, "rf")
    end
  end)

  it("writes the plugin under <cwd>/.vibing/, never the user's ~/.copilot", function()
    local dir = CopilotSettingsGenerator.ensure(tmp_dir)

    assert.equals(vim.fn.resolve(tmp_dir) .. "/.vibing/copilot-plugin", dir)
    assert.equals(1, vim.fn.filereadable(dir .. "/plugin.json"))
  end)

  it("names the plugin in kebab-case, which copilot requires", function()
    local manifest = read_manifest(tmp_dir)

    assert.equals("vibing-nvim-permissions", manifest.name)
    assert.is_truthy(manifest.name:match("^[a-z0-9%-]+$"))
  end)

  it("inlines the hooks as a bare event map", function()
    -- Not a path to a sibling hooks.json, and not the {"version":1,"hooks":…} envelope a
    -- standalone hooks file takes: copilot ignores that envelope when it is inlined here.
    local manifest = read_manifest(tmp_dir)

    assert.is_table(manifest.hooks)
    assert.is_table(manifest.hooks.preToolUse)
    assert.is_nil(manifest.hooks.hooks)
    assert.is_nil(manifest.hooks.version)
  end)

  it("registers pre-tool-use.sh as a preToolUse command hook in copilot's own schema", function()
    local entry = hook_entry(read_manifest(tmp_dir))

    assert.equals("command", entry.type)
    -- Copilot reads the command from `bash` and the timeout from `timeoutSec` — neither is
    -- Claude's `command`/`timeout`, so a copy of the Claude settings would load and do nothing.
    assert.is_string(entry.bash)
    assert.is_nil(entry.command)
    assert.is_nil(entry.timeout)
    local script = vim.fn.fnamemodify(SettingsGenerator.get_hook_script_path(), ":p")
    assert.is_truthy(entry.bash:find(script, 1, true), "must invoke the bundled hook script")
    assert.is_truthy(entry.bash:match("%f[%w]copilot$"), "must select the copilot decision format")
  end)

  it("omits the matcher, which copilot compiles as a regex", function()
    -- `*` is Claude's "all tools" matcher and an invalid regex here: copilot logs
    -- "Invalid matcher regex ... hook will be skipped" and every tool runs unchecked.
    assert.is_nil(hook_entry(read_manifest(tmp_dir)).matcher)
  end)

  it("allows more time than the hook script waits, because copilot fails open on timeout", function()
    -- Every non-zero exit denies, but a hook that outlives timeoutSec is ignored and the tool
    -- proceeds. This invariant spans two languages, so read the script's own budget rather than
    -- restating it: raising MAX_WAIT for Claude's sake would otherwise silently turn a slow
    -- copilot approval into an allow, with the suite still green.
    local script = io.open(vim.fn.fnamemodify(SettingsGenerator.get_hook_script_path(), ":p"), "r")
    local source = script:read("*a")
    script:close()

    local max_wait_ticks = tonumber(source:match("\nMAX_WAIT=(%d+)"))
    assert.is_not_nil(max_wait_ticks, "could not read MAX_WAIT out of pre-tool-use.sh")

    local script_wait_sec = max_wait_ticks / 10 -- the poll loop sleeps 0.1s per tick
    assert.is_true(
      hook_entry(read_manifest(tmp_dir)).timeoutSec > script_wait_sec,
      "copilot's hook timeout must outlast the script's own wait"
    )
  end)

  it("quotes the script path so a directory with a space stays one argument", function()
    local spaced = tmp_dir .. "/with space"
    vim.fn.mkdir(spaced, "p")

    local command = hook_entry(read_manifest(spaced)).bash
    assert.is_truthy(command:match("^['\"]"), "hook command must be shell-quoted: " .. command)
  end)

  it("rewrites the manifest when it is missing (the hook path moves on plugin update)", function()
    local dir = CopilotSettingsGenerator.ensure(tmp_dir)
    assert.equals(0, vim.fn.delete(dir .. "/plugin.json"))

    assert.equals(dir, CopilotSettingsGenerator.ensure(tmp_dir))
    assert.equals(1, vim.fn.filereadable(dir .. "/plugin.json"))
  end)

  it("leaves no temp file behind, so copilot never loads a half-written manifest", function()
    -- The manifest is renamed into place rather than truncated: every chat open on this cwd
    -- rewrites it just before spawning its own copilot, and an unreadable manifest means no hook
    -- at all — the one failure mode here that fails open.
    local dir = CopilotSettingsGenerator.ensure(tmp_dir)

    assert.are.same({}, vim.fn.glob(dir .. "/*.tmp", false, true))
  end)

  it("reports plugin_dir for a cwd without writing anything", function()
    local expected = vim.fn.resolve(tmp_dir) .. "/.vibing/copilot-plugin"
    assert.equals(expected, CopilotSettingsGenerator.plugin_dir(tmp_dir))
    assert.equals(0, vim.fn.isdirectory(expected))
    assert.equals(CopilotSettingsGenerator.ensure(tmp_dir), expected)
  end)
end)
