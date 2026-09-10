-- Tests for stamping the Assistant header at the end of a turn. The stamp is the only record of
-- when the prompt cache was last written, so what matters is that it lands on the header the turn
-- actually opened and on nothing else.

describe("streaming_handler.stamp_response_end", function()
  local StreamingHandler = require("vibing.presentation.chat.modules.streaming_handler")
  local Timestamp = require("vibing.core.utils.timestamp")

  local created_bufs

  before_each(function()
    created_bufs = {}
  end)

  after_each(function()
    for _, bufnr in ipairs(created_bufs) do
      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end
  end)

  --- @param lines string[]
  --- @return number bufnr
  local function scratch(lines)
    local bufnr = vim.api.nvim_create_buf(false, true)
    table.insert(created_bufs, bufnr)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    return bufnr
  end

  --- @param bufnr number
  --- @param line number
  --- @return string
  local function line_at(bufnr, line)
    return vim.api.nvim_buf_get_lines(bufnr, line - 1, line, false)[1]
  end

  it("stamps the header start_response opened", function()
    local bufnr = scratch({ "## User <!-- 2026-09-04 10:00:00 -->", "hi" })

    local header_line = StreamingHandler.start_response(bufnr)
    vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, { "an answer" })
    StreamingHandler.stamp_response_end(bufnr, header_line)

    local header = Timestamp.parse_header(line_at(bufnr, header_line))
    assert.equals("Assistant", header.kind)
    assert.is_number(Timestamp.to_epoch(header.timestamp))
  end)

  it("leaves a reply that quotes the chat format alone", function()
    -- `parse_header`'s legacy branch matches a bare `## Assistant` at column 0 anywhere, so a
    -- reply documenting the transcript format (README.md does exactly this) used to get its own
    -- body rewritten while the real header stayed unstamped.
    local bufnr = scratch({ "## User <!-- 2026-09-04 10:00:00 -->", "explain the format" })

    local header_line = StreamingHandler.start_response(bufnr)
    vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, { "Sections look like this:", "", "## Assistant", "" })
    StreamingHandler.stamp_response_end(bufnr, header_line)

    assert.is_number(Timestamp.to_epoch(Timestamp.parse_header(line_at(bufnr, header_line)).timestamp))
    assert.equals("## Assistant", line_at(bufnr, vim.api.nvim_buf_line_count(bufnr) - 1))
  end)

  it("does nothing without a recorded header line", function()
    local bufnr = scratch({ "## Assistant", "an answer" })

    StreamingHandler.stamp_response_end(bufnr, nil)

    assert.equals("## Assistant", line_at(bufnr, 1))
  end)

  it("does nothing when the recorded line is no longer that header", function()
    local bufnr = scratch({ "## Assistant <!-- 2026-09-04 10:05:00 -->", "an answer" })

    StreamingHandler.stamp_response_end(bufnr, 1)

    assert.equals("## Assistant <!-- 2026-09-04 10:05:00 -->", line_at(bufnr, 1))
  end)

  -- ストリームは行の途中でも切れるので、フェンスの正規化はチャンクの切れ目に依存しては
  -- いけない。閉じフェンスに文章が続く行を1つでも残すと、そこから下が全部コードとして
  -- ハイライトされる（tree-sitter-vibing/src/scanner.c）
  describe("flush_chunks", function()
    it("splits prose that follows a closing fence", function()
      local bufnr = scratch({ "## Assistant", "" })

      StreamingHandler.flush_chunks(bufnr, nil, "```lua\nlocal x = 1\n```これで完了です\n")

      assert.same({
        "## Assistant",
        "```lua",
        "local x = 1",
        "```",
        "これで完了です",
        "",
      }, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
    end)

    it("splits the same way when the chunk boundary falls inside the line", function()
      local bufnr = scratch({ "## Assistant", "" })

      StreamingHandler.flush_chunks(bufnr, nil, "```lua\nlocal x = 1\n```これ")
      StreamingHandler.flush_chunks(bufnr, nil, "で完了です\n")

      assert.same({
        "## Assistant",
        "```lua",
        "local x = 1",
        "```",
        "これで完了です",
        "",
      }, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
    end)

    it("keeps a language-name-looking line inside the block", function()
      local bufnr = scratch({ "## Assistant", "" })

      StreamingHandler.flush_chunks(bufnr, nil, "````markdown\n")
      StreamingHandler.flush_chunks(bufnr, nil, "```json\n")
      StreamingHandler.flush_chunks(bufnr, nil, "````\n")

      assert.same({
        "## Assistant",
        "````markdown",
        "```json",
        "````",
        "",
      }, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
    end)

    it("does not carry a fence across the message header", function()
      local bufnr = scratch({ "## User <!-- 2026-09-04 10:00:00 -->", "```lua", "local x = 1", "## Assistant", "" })

      StreamingHandler.flush_chunks(bufnr, nil, "```これは新しいブロックです\n")

      assert.equals("```これは新しいブロックです", line_at(bufnr, 5))
    end)
  end)
end)
