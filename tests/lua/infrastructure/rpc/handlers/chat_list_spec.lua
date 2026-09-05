-- Tests for the `list_chats` RPC method backing the nvim_chat_list MCP tool (#695).
-- An orchestrator driving several worker chats otherwise has to poll each one individually with
-- nvim_get_buffer -- N chats, N round trips (#692's postmortem worked around exactly this with a
-- hand-rolled Python RPC poller). list_chats answers for all of them in one call.

local ChatBuffers = require("tests.helpers.chat_buffers")

describe("rpc handlers: list_chats", function()
  local handler

  before_each(function()
    ChatBuffers.setup()
    handler = require("vibing.infrastructure.rpc.handlers.chat")
  end)

  after_each(ChatBuffers.reset)

  it("returns an empty list when no chat is open", function()
    local result = handler.list_chats({})

    assert.same({}, result.chats)
  end)

  it("lists every open chat with its bufnr and file_path", function()
    local first = handler.create_chat({})
    local second = handler.create_chat({})

    local result = handler.list_chats({})

    assert.equals(2, #result.chats)
    local bufnrs = { result.chats[1].bufnr, result.chats[2].bufnr }
    table.sort(bufnrs)
    assert.same({ first.bufnr, second.bufnr }, bufnrs)
    for _, chat in ipairs(result.chats) do
      assert.is_true(chat.file_path == first.file_path or chat.file_path == second.file_path)
    end
  end)

  it("reports a freshly created chat as idle", function()
    local created = handler.create_chat({})

    local result = handler.list_chats({})

    assert.equals("idle", result.chats[1].chat_status)
    assert.equals(created.bufnr, result.chats[1].bufnr)
  end)

  it("reports the task a chat was created with (#696)", function()
    local created = handler.create_chat({ task = "PR #688 — review fixes, merge, cleanup" })

    local result = handler.list_chats({})

    assert.equals(created.bufnr, result.chats[1].bufnr)
    assert.equals("PR #688 — review fixes, merge, cleanup", result.chats[1].task)
  end)

  it("reports no task for a chat created without one", function()
    handler.create_chat({})

    local result = handler.list_chats({})

    assert.is_nil(result.chats[1].task)
  end)

  it("reports no context_size for a chat that has not completed a turn", function()
    handler.create_chat({})

    local result = handler.list_chats({})

    assert.is_nil(result.chats[1].context_size)
  end)

  it("reads context_size back from a written ### Tokens marker", function()
    local created = handler.create_chat({})
    vim.api.nvim_buf_set_lines(created.bufnr, -1, -1, false, {
      "### Tokens <!-- context=12345 -->",
      "",
      "context 12.3k · 1 request · read 10k · new 2k",
    })

    local result = handler.list_chats({})

    assert.equals(12345, result.chats[1].context_size)
  end)

  it("finds the marker even when the first (smallest) tail chunk misses it", function()
    -- The chunked backward scan (#711 review) starts at a 500-line tail and doubles until it
    -- finds the marker or covers the whole buffer -- it must not stop after the first miss.
    local created = handler.create_chat({})
    vim.api.nvim_buf_set_lines(created.bufnr, -1, -1, false, {
      "### Tokens <!-- context=99999 -->",
      "",
      "context 100k · 1 request · read 90k · new 10k",
    })
    local filler = {}
    for i = 1, 600 do
      filler[i] = "filler line " .. i
    end
    vim.api.nvim_buf_set_lines(created.bufnr, -1, -1, false, filler)

    local result = handler.list_chats({})

    assert.equals(99999, result.chats[1].context_size)
  end)

  it("reports the updated_at frontmatter timestamp once something has written it", function()
    -- A bare create_chat() writes only vibing.nvim/session_id/created_at (renderer.lua) --
    -- updated_at is stamped the first time any field actually updates (frontmatter_handler.lua),
    -- which linking an orchestrator does.
    local orchestrator = handler.create_chat({})
    local worker = handler.create_chat({ from_bufnr = orchestrator.bufnr })

    local result = handler.list_chats({})

    local worker_entry
    for _, chat in ipairs(result.chats) do
      if chat.bufnr == worker.bufnr then
        worker_entry = chat
      end
    end

    assert.is_string(worker_entry.updated_at)
  end)

  it("reports orchestrated_by for a worker chat created with from_bufnr", function()
    local orchestrator = handler.create_chat({})
    local worker = handler.create_chat({ from_bufnr = orchestrator.bufnr })

    local result = handler.list_chats({})

    local worker_entry
    for _, chat in ipairs(result.chats) do
      if chat.bufnr == worker.bufnr then
        worker_entry = chat
      end
    end

    assert.is_not_nil(worker_entry)
    assert.equals(1, #worker_entry.orchestrated_by)
  end)

  it("reports an empty orchestrated_by list for a chat with no orchestrator", function()
    handler.create_chat({})

    local result = handler.list_chats({})

    assert.same({}, result.chats[1].orchestrated_by)
  end)
end)
