--- The wiring from a finished turn to the `↻` note and the `floor` line.
---
--- `prefix_rewrite_spec.lua` pins the rules; this pins that a real response reaches them --
--- which facts are taken from the CLI's `init` event, which from frontmatter, and that this
--- turn is recorded for the next one to compare against. A break here reports "no likely cause
--- found" on every turn forever, with nothing else failing.
describe("send_message prefix-rewrite reporting", function()
  local SendMessage = require("vibing.application.chat.send_message")
  local TokenUsage = require("vibing.core.utils.token_usage")
  local TurnState = require("vibing.infrastructure.storage.turn_state")

  local dir, chat_path, bufnr, chunks, callbacks

  --- A turn that re-wrote essentially its whole context.
  local function rewriting_turn(cli_info)
    local acc = TokenUsage.new()
    acc.requests = 3
    acc.context = 200000
    acc.read = 400000
    acc.write = 198000
    acc.first_context = 200000
    acc.first_write = 198000
    return { _token_usage = acc, _cli_info = cli_info or { model = "claude-opus-5", version = "2.1.231" } }
  end

  --- A turn that only appended to a prefix it reused.
  local function warm_turn()
    local acc = TokenUsage.new()
    acc.requests = 3
    acc.context = 200000
    acc.read = 400000
    acc.write = 9000
    acc.first_context = 200000
    acc.first_write = 3000
    return { _token_usage = acc, _cli_info = { model = "claude-opus-5", version = "2.1.231" } }
  end

  local function written()
    return table.concat(chunks, "")
  end

  --- Everything written, with the blockquote's line breaks unwrapped.
  ---
  --- The note wraps at a readable width, so a phrase like "the model changed (a to b)" can be
  --- split across two `> ` lines. Asserting against the raw text would make every one of these
  --- cases depend on where the wrap happens to land.
  local function unwrapped()
    return (written():gsub("\n> ", " "))
  end

  local frontmatter

  before_each(function()
    TurnState.clear_cache()
    dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    chat_path = dir .. "/chat.md"
    vim.fn.writefile({ "" }, chat_path)

    bufnr = vim.fn.bufadd(chat_path)
    vim.fn.bufload(bufnr)

    chunks = {}
    frontmatter = { model = "opus", effort = "high" }
    callbacks = {
      append_chunk = function(chunk)
        table.insert(chunks, chunk)
      end,
      get_bufnr = function()
        return bufnr
      end,
      get_cwd = function()
        return dir
      end,
      parse_frontmatter = function()
        return frontmatter
      end,
    }
  end)

  after_each(function()
    if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end
    vim.fn.delete(dir, "rf")
    TurnState.clear_cache()
  end)

  it("names an expired cache TTL", function()
    TurnState.record(chat_path, {
      at = os.time() - 7200,
      model = "claude-opus-5",
      effort = "high",
      version = "2.1.231",
    })

    SendMessage._report_token_usage(rewriting_turn(), callbacks, {})

    assert.truthy(unwrapped():find("Prefix rewritten (198k)", 1, true))
    assert.truthy(unwrapped():find("2h00m since the last turn", 1, true))
  end)

  it("names a model change, taking the model the CLI actually ran with", function()
    TurnState.record(chat_path, {
      at = os.time() - 60,
      model = "claude-sonnet-5",
      effort = "high",
      version = "2.1.231",
    })

    -- Frontmatter says "opus" both times; only the init event distinguishes the two turns, which
    -- is why the resolved model is preferred over the field a user can edit mid-turn.
    SendMessage._report_token_usage(rewriting_turn(), callbacks, {})

    assert.truthy(unwrapped():find("the model changed (claude-sonnet-5 to claude-opus-5)", 1, true))
  end)

  it("names an edited rules file", function()
    local last_turn = os.time() - 60
    TurnState.record(chat_path, {
      at = last_turn,
      model = "claude-opus-5",
      effort = "high",
      version = "2.1.231",
    })
    vim.fn.mkdir(dir .. "/.claude/rules", "p")
    vim.fn.writefile({ "rule" }, dir .. "/.claude/rules/architecture.md")
    vim.uv.fs_utime(dir .. "/.claude/rules/architecture.md", last_turn + 30, last_turn + 30)

    SendMessage._report_token_usage(rewriting_turn(), callbacks, {})

    assert.truthy(unwrapped():find(".claude/rules/architecture.md edited since the last turn", 1, true))
  end)

  it("adds nothing to a turn that reused its prefix", function()
    TurnState.record(chat_path, { at = os.time() - 7200, model = "claude-opus-5", version = "2.1.231" })

    SendMessage._report_token_usage(warm_turn(), callbacks, {})

    -- Every cause above applies to this turn too; none of them matters, because the cache was hit.
    assert.truthy(written():find("context 200k", 1, true))
    assert.is_nil(written():find("↻", 1, true))
  end)

  it("adds nothing on a chat's very first turn", function()
    SendMessage._report_token_usage(rewriting_turn(), callbacks, {})

    -- The first turn writes its whole prefix by definition. It is the cache being filled.
    assert.is_nil(written():find("↻", 1, true))
  end)

  it("adds nothing on the first turn of a reset session, history or not", function()
    TurnState.record(chat_path, { at = os.time() - 7200, model = "claude-opus-5", version = "2.1.231" })

    SendMessage._report_token_usage(rewriting_turn(), callbacks, {}, true)

    -- `/new-session` on a chat that already has turns: there is a previous record to compare
    -- against and every cause would come up empty, so the note would say "no likely cause found"
    -- about the one case whose cause is not in doubt.
    assert.is_nil(written():find("↻", 1, true))
  end)

  it("still records the turn a reset session was not asked about", function()
    TurnState.record(chat_path, { at = os.time() - 7200, model = "claude-sonnet-5", version = "2.1.231" })

    SendMessage._report_token_usage(rewriting_turn(), callbacks, {}, true)

    -- Skipping the note must not skip the bookkeeping, or the turn after it compares against a
    -- record two turns old.
    assert.equals("claude-opus-5", TurnState.load(chat_path).model)
  end)

  it("records this turn for the next one to compare against", function()
    SendMessage._report_token_usage(rewriting_turn(), callbacks, {})

    local recorded = TurnState.load(chat_path)
    assert.equals("claude-opus-5", recorded.model)
    assert.equals("high", recorded.effort)
    assert.equals("2.1.231", recorded.version)
    assert.is_false(recorded.compacted)
  end)

  it("carries a compaction forward so the next turn can blame it", function()
    SendMessage._report_token_usage(
      rewriting_turn({ model = "claude-opus-5", version = "2.1.231", compacted = true }),
      callbacks,
      {}
    )
    chunks = {}
    SendMessage._report_token_usage(rewriting_turn(), callbacks, {})

    assert.truthy(unwrapped():find("compacted", 1, true))
  end)

  it("records nothing for a turn it had nothing to report on", function()
    SendMessage._report_token_usage({}, callbacks, {})

    -- Recording here would make the next turn measure its TTL gap from a moment nothing happened.
    assert.is_nil(TurnState.load(chat_path))
  end)

  describe("floor", function()
    local function first_turn()
      local acc = TokenUsage.new()
      acc.requests = 2
      acc.context = 112000
      acc.read = 112000
      acc.write = 112000
      acc.first_context = 112000
      acc.first_write = 112000
      return {
        _token_usage = acc,
        _cli_info = { model = "claude-opus-5", version = "2.1.231", tools = 322, mcp_servers = 23 },
      }
    end

    it("states the floor on a session's first turn", function()
      SendMessage._report_token_usage(first_turn(), callbacks, {}, true)

      assert.truthy(written():find("floor ~112k (322 tools, 23 MCP servers)", 1, true))
    end)

    it("leaves it off every later turn", function()
      SendMessage._report_token_usage(first_turn(), callbacks, {}, false)

      assert.is_nil(written():find("floor", 1, true))
    end)
  end)

  it("still writes the breakdown when the diagnosis cannot run", function()
    callbacks.get_bufnr = function()
      error("buffer gone")
    end

    SendMessage._report_token_usage(rewriting_turn(), callbacks, {})

    -- A missing cause line is a worse report; a missing section is a regression against #669.
    assert.truthy(written():find("context 200k", 1, true))
  end)
end)
