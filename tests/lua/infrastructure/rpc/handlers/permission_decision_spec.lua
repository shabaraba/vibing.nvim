---@diagnostic disable: undefined-field
--- What the handler writes into the .res file is the whole permission contract with the CLI, and
--- it is three-valued rather than two: an allowed call is either granted outright or handed back
--- to the CLI's own gate. Before #564 every allowed call took the second path, which in headless
--- `-p` mode simply refuses vibing-nvim's own MCP tools.
local permission = require("vibing.infrastructure.rpc.handlers.permission")

local HANDLE_ID = "decision-spec-handle"

local comm_dir

local function write_request(request_id, tool_name, tool_input)
  local f = assert(io.open(comm_dir .. "/" .. request_id .. ".req", "w"))
  f:write(vim.json.encode({ tool_name = tool_name, tool_input = tool_input or {} }))
  f:close()
end

--- @return table hookSpecificOutput
local function decide(request_id, tool_name, tool_input)
  write_request(request_id, tool_name, tool_input)
  permission.check_tool_permission({ request_id = request_id, handle_id = HANDLE_ID })

  local f = assert(io.open(comm_dir .. "/" .. request_id .. ".res", "r"))
  local content = f:read("*a")
  f:close()
  return vim.json.decode(content).hookSpecificOutput
end

describe("permission handler hook decision", function()
  local original_comm_dir

  before_each(function()
    original_comm_dir = vim.env.VIBING_HOOK_COMM_DIR
    comm_dir = vim.fn.tempname()
    vim.fn.mkdir(comm_dir, "p")
    vim.env.VIBING_HOOK_COMM_DIR = comm_dir
    permission.set_active_opts(HANDLE_ID, {
      permissions_allow = { "Read" },
      permissions_deny = { "Bash" },
      permission_mode = "acceptEdits",
    })
  end)

  after_each(function()
    permission.clear_active_opts(HANDLE_ID)
    vim.env.VIBING_HOOK_COMM_DIR = original_comm_dir
    vim.fn.delete(comm_dir, "rf")
  end)

  it("grants vibing-nvim's own MCP tools outright", function()
    local output = decide("req-mcp", "mcp__plugin_vibing-nvim_vibing-nvim__nvim_list_windows", {})

    assert.equals("allow", output.permissionDecision)
    -- Without hookEventName the CLI does not read the object as a PreToolUse decision at all.
    assert.equals("PreToolUse", output.hookEventName)
  end)

  it("grants them whatever marketplace the plugin was installed from", function()
    -- The prefix is decided at install time and cannot be known here, which is exactly why the
    -- grant has to come from this suffix match rather than from --allowedTools.
    local output = decide("req-mcp-alt", "mcp__plugin_some-other-name_vibing-nvim__nvim_get_buffer", {})

    assert.equals("allow", output.permissionDecision)
  end)

  it("defers an ordinary allowed tool to the CLI's own gate", function()
    -- Not "allow": granting every permitted tool would also override the deny rules in the user's
    -- own settings.json, which --setting-sources still pulls in.
    local output = decide("req-read", "Read", { file_path = "/tmp/x.lua" })

    assert.equals("defer", output.permissionDecision)
  end)

  it("denies with the reason attached", function()
    local output = decide("req-bash", "Bash", { command = "echo hi" })

    assert.equals("deny", output.permissionDecision)
    assert.is_truthy(output.permissionDecisionReason)
  end)
end)
