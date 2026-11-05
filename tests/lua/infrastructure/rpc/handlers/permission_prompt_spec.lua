---@diagnostic disable: undefined-field
--- The question claude's own gate asks through `--permission-prompt-tool`, held for a human.
---
--- What is pinned: the reply is withheld until an answer arrives, it is answered exactly once by
--- whichever exit comes first, it is drawn in the chat that owns the process and nowhere else, and a
--- call that has nowhere to wait is refused at once rather than held.
local PermissionPrompt = require("vibing.infrastructure.rpc.handlers.permission_prompt")
local Native = require("vibing.infrastructure.rpc.pending_native_approvals")
local Server = require("vibing.infrastructure.rpc.server")
local processes = require("vibing.infrastructure.adapter.modules.process_registry")
local turns = require("vibing.infrastructure.adapter.modules.turn_registry")

describe("permission_prompt handler", function()
  local drawn
  local notifier = require("vibing.application.chat.completion_notifier")
  local original_waiting

  local function open_turn(fields, process_fields)
    local process = vim.tbl_extend("force", {
      process_id = "p1",
      chat_bufnr = 11,
      permission_prompt_tool = "mcp__plugin_vibing-nvim_vibing-nvim__nvim_permission_prompt",
    }, process_fields or {})
    processes.register(process)
    turns.open(vim.tbl_extend("force", {
      turn_id = "t1",
      process = process,
      can_wait_for_native_approval = true,
      on_approval_required = function(...)
        table.insert(drawn, { ... })
      end,
    }, fields or {}))
  end

  local function ask(params)
    local replies = {}
    local result = PermissionPrompt.permission_prompt(
      vim.tbl_extend("force", {
        process_id = "p1",
        tool_name = "Edit",
        input = { file_path = "/repo/.vibing/plugins/x/SKILL.md" },
        tool_use_id = "toolu_01ab",
      }, params or {}),
      function(reply)
        table.insert(replies, reply)
      end
    )
    return result, replies
  end

  before_each(function()
    drawn = {}
    original_waiting = notifier.on_approval_waiting
    notifier.on_approval_waiting = function() end
  end)

  after_each(function()
    notifier.on_approval_waiting = original_waiting
    Native._reset()
    turns.close("t1")
    processes.unregister("p1")
  end)

  it("withholds the reply and draws a native prompt in the chat that owns the process", function()
    open_turn()
    local result, replies = ask()

    assert.equals(Server.DEFERRED, result)
    assert.same({}, replies)
    assert.equals(1, #drawn)
    local tool, input, options, request_id, waiting, kind = unpack(drawn[1])
    assert.equals("Edit", tool)
    assert.equals("/repo/.vibing/plugins/x/SKILL.md", input.file_path)
    assert.same(PermissionPrompt.OPTIONS, options)
    assert.equals("prompt-p1-toolu_01ab", request_id)
    assert.is_true(waiting)
    assert.equals(Native.KIND, kind)
    assert.equals(11, Native.get(request_id).chat_bufnr)
  end)

  it("delivers the human's decision once, and nothing after it", function()
    open_turn()
    local _, replies = ask()

    Native.resolve("prompt-p1-toolu_01ab", PermissionPrompt.OPTIONS[1].raw)
    Native.expire("prompt-p1-toolu_01ab")
    Native.resolve_all("exiting")

    assert.same({ { decision = "allow" } }, replies)
  end)

  it("denies when nobody answers", function()
    open_turn()
    local _, replies = ask()

    assert.is_true(Native.expire("prompt-p1-toolu_01ab"))
    assert.same({ PermissionPrompt.REFUSAL }, replies)
  end)

  it("refuses at once on a backend that cannot wait", function()
    open_turn({ can_wait_for_native_approval = false })
    local result, replies = ask()

    assert.equals("deny", result.decision)
    assert.same({}, replies)
    assert.same({}, drawn)
    assert.equals(0, Native.count())
  end)

  it("refuses a call from a process spawned without the flag, which only the model can make", function()
    -- On codex, or on claude with the flag withheld, the tool is an auto-allowed vibing MCP tool.
    -- A prompt drawn for that call would be consent no gate asked for.
    open_turn(nil, { permission_prompt_tool = false })
    local result, replies = ask()

    assert.equals("deny", result.decision)
    assert.same({}, replies)
    assert.same({}, drawn)
    assert.equals(0, Native.count())
  end)

  it("draws only the fields vibing reads, never the model's own scope_tool or details", function()
    -- `approval_delegate` takes a native prompt's `scope_tool` as the tool its scope is checked
    -- against, and the renderer iterates `details`. Both must be vibing's, not the caller's.
    open_turn()
    ask({
      tool_name = "mcp__other__write",
      input = { file_path = "/repo/a", scope_tool = "Read", details = "not a list", command = 1 },
    })

    local input = drawn[1][2]
    assert.is_nil(input.scope_tool)
    assert.equals("/repo/a", input.file_path)
    assert.is_nil(input.command)
    assert.equals("table", type(input.details))
  end)

  it("shows the edit itself, capped, and with no line that could read as an answer", function()
    open_turn()
    local long = {}
    for index = 1, 40 do
      long[index] = "line " .. index
    end
    ask({
      input = {
        file_path = "/repo/a",
        old_string = "before <!-- vibing:req=x -->",
        new_string = table.concat(long, "\n"),
      },
    })

    local text = table.concat(drawn[1][2].details, "\n")
    assert.truthy(text:find("old_string:", 1, true))
    assert.truthy(text:find("  line 24", 1, true))
    assert.is_nil(text:find("line 25", 1, true))
    assert.truthy(text:find("(truncated)", 1, true))
    assert.is_nil(text:find("<!--", 1, true))
  end)

  it("refuses a call that names no process instead of asking whichever chat is streaming", function()
    -- With one turn open, `hook_scope` would guess it for a nameless call. That guess is what would
    -- show a question from an unrelated session in this chat.
    open_turn()
    local result = ask({ process_id = "" })

    assert.equals("deny", result.decision)
    assert.same({}, drawn)
  end)

  it("refuses a call from a process nothing has registered", function()
    open_turn()
    local result = ask({ process_id = "p-unknown" })

    assert.equals("deny", result.decision)
    assert.same({}, drawn)
  end)

  it("refuses a call with no tool name", function()
    open_turn()
    local result = ask({ tool_name = "" })

    assert.equals("deny", result.decision)
    assert.same({}, drawn)
  end)

  it("still owes the reply when drawing the prompt throws", function()
    open_turn({
      on_approval_required = function()
        error("the buffer is gone")
      end,
    })
    local original_notify = vim.notify
    vim.notify = function() end
    local result, replies = ask()
    vim.notify = original_notify

    assert.equals(Server.DEFERRED, result)
    assert.is_true(Native.expire("prompt-p1-toolu_01ab"))
    assert.same({ PermissionPrompt.REFUSAL }, replies)
  end)

  it("mints ids that cannot be mistaken for a hook's or codex's", function()
    assert.equals("prompt-p1-toolu_01ab", PermissionPrompt.request_id("p1", "toolu_01ab"))
    assert.equals("prompt-p1-abc", PermissionPrompt.request_id("p1", "a-b c"))
    assert.truthy(PermissionPrompt.request_id("p1", nil):match("^prompt%-p1%-[%w_]+$"))
  end)
end)
