--- Grok-specific permission handler behavior (camelCase payload + tool aliases)
local permission = require("vibing.infrastructure.rpc.handlers.permission")

describe("permission handler (Grok)", function()
  local handle_id = "test_handle_grok"
  local request_id
  local comm_dir
  local original_get_port

  local function write_req(payload)
    vim.fn.mkdir(comm_dir, "p")
    local path = comm_dir .. "/" .. request_id .. ".req"
    local f = assert(io.open(path, "w"))
    f:write(vim.json.encode(payload))
    f:close()
  end

  local function read_res()
    local path = comm_dir .. "/" .. request_id .. ".res"
    local f = io.open(path, "r")
    if not f then
      return nil
    end
    local content = f:read("*a")
    f:close()
    local ok, decoded = pcall(vim.json.decode, content)
    if not ok then
      return nil
    end
    return decoded
  end

  before_each(function()
    request_id = "req-" .. tostring(math.random(100000, 999999))
    -- Mock RPC port so get_comm_dir points at a predictable location
    local rpc_server = require("vibing.infrastructure.rpc.server")
    original_get_port = rpc_server.get_port
    rpc_server.get_port = function()
      return 19999
    end
    comm_dir = "/tmp/vibing-hook-19999"
    vim.fn.delete(comm_dir, "rf")
    vim.fn.mkdir(comm_dir, "p")

    permission.set_active_opts(handle_id, {
      _is_grok = true,
      permission_mode = "default",
      permissions_allow = { "Read", "Edit", "Write", "Glob", "Grep" },
      permissions_deny = { "Bash" },
      permissions_ask = {},
    })
  end)

  after_each(function()
    permission.clear_active_opts(handle_id)
    local rpc_server = require("vibing.infrastructure.rpc.server")
    rpc_server.get_port = original_get_port
    vim.fn.delete(comm_dir, "rf")
  end)

  it("accepts Grok camelCase toolName/toolInput and maps run_terminal_command → Bash deny", function()
    write_req({
      hookEventName = "pre_tool_use",
      toolName = "run_terminal_command",
      toolInput = { command = "echo hi" },
    })

    local result = permission.check_tool_permission({
      request_id = request_id,
      handle_id = handle_id,
    })

    assert.equals("denied", result.status)
    local res = read_res()
    assert.is_not_nil(res)
    assert.equals("deny", res.hookSpecificOutput.permissionDecision)
  end)

  it("maps read_file → Read and allows when Read is in allow list", function()
    write_req({
      toolName = "read_file",
      toolInput = { path = "README.md" },
    })

    local result = permission.check_tool_permission({
      request_id = request_id,
      handle_id = handle_id,
    })

    assert.equals("allowed", result.status)
    local res = read_res()
    assert.equals("allow", res.hookSpecificOutput.permissionDecision)
  end)

  it("maps search_replace → Edit", function()
    write_req({
      toolName = "search_replace",
      toolInput = { path = "foo.lua" },
    })

    local result = permission.check_tool_permission({
      request_id = request_id,
      handle_id = handle_id,
    })

    assert.equals("allowed", result.status)
  end)
end)
