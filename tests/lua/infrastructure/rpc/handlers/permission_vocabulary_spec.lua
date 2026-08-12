---@diagnostic disable: undefined-field
--- The tool-name translation path had no test before #516: the codex alias table lived in this
--- handler and was only exercised end-to-end. Now that adapters inject their own vocabulary, this
--- pins the contract the handler relies on — and that it works for a backend it knows nothing
--- about.
local permission = require("vibing.infrastructure.rpc.handlers.permission")

local HANDLE_ID = "vocabulary-spec-handle"

local comm_dir

--- Write the hook payload the way bin/hooks/pre-tool-use.sh does.
local function write_request(request_id, tool_name, tool_input)
  local f = assert(io.open(comm_dir .. "/" .. request_id .. ".req", "w"))
  f:write(vim.json.encode({ tool_name = tool_name, tool_input = tool_input or {} }))
  f:close()
end

local function read_response(request_id)
  local f = io.open(comm_dir .. "/" .. request_id .. ".res", "r")
  if not f then
    return nil
  end
  local content = f:read("*a")
  f:close()
  local ok, decoded = pcall(vim.json.decode, content)
  return ok and decoded or content
end

describe("permission handler tool vocabulary", function()
  local original_comm_dir

  before_each(function()
    original_comm_dir = vim.env.VIBING_HOOK_COMM_DIR
    comm_dir = vim.fn.tempname()
    vim.fn.mkdir(comm_dir, "p")
    vim.env.VIBING_HOOK_COMM_DIR = comm_dir
  end)

  after_each(function()
    permission.clear_active_opts(HANDLE_ID)
    vim.env.VIBING_HOOK_COMM_DIR = original_comm_dir
    vim.fn.delete(comm_dir, "rf")
  end)

  it("denies a native tool name once its vocabulary maps it onto a denied canonical name", function()
    -- The codex case, expressed generically: apply_patch has to be judged as Edit.
    permission.set_active_opts(HANDLE_ID, {
      permissions_deny = { "Edit" },
      _tool_vocabulary = {
        to_canonical = function(name)
          return name == "apply_patch" and "Edit" or nil
        end,
      },
    })

    write_request("req-mapped", "apply_patch", { file_path = "/tmp/x.lua" })
    local result = permission.check_tool_permission({ request_id = "req-mapped", handle_id = HANDLE_ID })

    assert.equals("denied", result.status)
  end)

  it("leaves a name the vocabulary does not know alone", function()
    permission.set_active_opts(HANDLE_ID, {
      permissions_deny = { "Edit" },
      _tool_vocabulary = {
        to_canonical = function()
          return nil
        end,
      },
    })

    write_request("req-unmapped", "Read", {})
    local result = permission.check_tool_permission({ request_id = "req-unmapped", handle_id = HANDLE_ID })

    assert.equals("allowed", result.status)
  end)

  it("works with no vocabulary at all, the way claude_cli registers", function()
    -- Guards the nil path: a backend that names its tools canonically must not need to supply an
    -- identity table just to be understood.
    permission.set_active_opts(HANDLE_ID, { permissions_deny = { "Edit" } })

    write_request("req-none", "Edit", { file_path = "/tmp/x.lua" })
    local result = permission.check_tool_permission({ request_id = "req-none", handle_id = HANDLE_ID })

    assert.equals("denied", result.status)
    assert.is_not_nil(read_response("req-none"))
  end)

  it("ignores a vocabulary that does not implement to_canonical", function()
    permission.set_active_opts(HANDLE_ID, {
      permissions_deny = { "Edit" },
      _tool_vocabulary = {},
    })

    write_request("req-partial", "Edit", { file_path = "/tmp/x.lua" })
    local result = permission.check_tool_permission({ request_id = "req-partial", handle_id = HANDLE_ID })

    assert.equals("denied", result.status)
  end)

  it("is the table codex_cli actually hands over", function()
    local vocabulary = require("vibing.infrastructure.adapter.modules.codex_tool_vocabulary")
    assert.equals("Edit", vocabulary.to_canonical("apply_patch"))
    assert.is_nil(vocabulary.to_canonical("Read"))
  end)
end)
