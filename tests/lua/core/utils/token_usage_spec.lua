describe("token_usage", function()
  local TokenUsage = require("vibing.core.utils.token_usage")

  local function usage(input, write, read, output)
    return {
      input_tokens = input,
      cache_creation_input_tokens = write,
      cache_read_input_tokens = read,
      output_tokens = output,
    }
  end

  describe("record", function()
    it("counts one request per assistant message and sums every token kind", function()
      local acc = TokenUsage.new()
      TokenUsage.record(acc, usage(2, 1000, 50000, 300))
      TokenUsage.record(acc, usage(2, 500, 51000, 120))

      assert.equals(2, acc.requests)
      assert.equals(1500, acc.write)
      assert.equals(101000, acc.read)
      -- Output tokens are not accumulated: ~11% of the bill, and showing them beside the
      -- numbers that do move the total would invite shortening replies to save nothing.
      assert.is_nil(acc.output)
    end)

    it("reports the largest prompt as the context size", function()
      local acc = TokenUsage.new()
      TokenUsage.record(acc, usage(2, 1000, 50000, 10))
      TokenUsage.record(acc, usage(2, 800, 60000, 10))
      -- A later request can be smaller (a compaction, a fresh prefix); the gauge is how big the
      -- conversation actually got, not where it happens to have landed.
      TokenUsage.record(acc, usage(2, 100, 20000, 10))

      assert.equals(60802, acc.context)
    end)

    it("keeps a subagent's tokens but not its context", function()
      local acc = TokenUsage.new()
      TokenUsage.record(acc, usage(2, 1000, 200000, 50), false)
      TokenUsage.record(acc, usage(2, 500, 80000, 20), true)

      assert.equals(1, acc.requests)
      assert.equals(1, acc.subagent_requests)
      -- The subagent runs in its own, smaller context, so it must not move the main gauge --
      -- but its tokens were still spent.
      assert.equals(201002, acc.context)
      assert.equals(280000, acc.read)
      assert.equals(1500, acc.write)
    end)

    it("ignores a usage payload of an unexpected shape instead of erroring", function()
      local acc = TokenUsage.new()
      TokenUsage.record(acc, nil)
      TokenUsage.record(acc, "not a table")
      TokenUsage.record(acc, {})
      TokenUsage.record(nil, usage(1, 1, 1, 1))

      -- An empty table is still a request the CLI made; it just reports no numbers.
      assert.equals(1, acc.requests)
      assert.equals(0, acc.read)
      assert.equals(0, acc.context)
    end)
  end)

  describe("format", function()
    it("names context, request count and both cache directions", function()
      local acc = TokenUsage.new()
      TokenUsage.record(acc, usage(2, 12000, 205000, 900))
      TokenUsage.record(acc, usage(2, 400, 206000, 100))

      local line = TokenUsage.format(acc)

      assert.truthy(line:find("context 217k", 1, true))
      assert.truthy(line:find("2 requests", 1, true))
      assert.truthy(line:find("read 411k", 1, true))
      assert.truthy(line:find("new 12k", 1, true))
    end)

    it("mentions subagents only when there were some", function()
      local acc = TokenUsage.new()
      TokenUsage.record(acc, usage(2, 100, 1000, 10))
      assert.is_nil(TokenUsage.format(acc):find("subagent", 1, true))

      TokenUsage.record(acc, usage(2, 100, 1000, 10), true)
      assert.truthy(TokenUsage.format(acc):find("1 subagent", 1, true))
    end)

    it("says nothing for a turn that made no main-chain request", function()
      assert.is_nil(TokenUsage.format(TokenUsage.new()))
      assert.is_nil(TokenUsage.format(nil))

      -- A backend that reports no usage at all (codex, grok) lands here rather than printing zeros.
      local acc = TokenUsage.new()
      TokenUsage.record(acc, usage(1, 1, 1, 1), true)
      assert.is_nil(TokenUsage.format(acc))
    end)

    it("uses one unit per magnitude so the line stays scannable", function()
      assert.equals("999", TokenUsage._humanize(999))
      assert.equals("1k", TokenUsage._humanize(1000))
      assert.equals("205k", TokenUsage._humanize(205000))
      assert.equals("2.4M", TokenUsage._humanize(2400000))
    end)

    it("switches to M where the k form would round to 1000k", function()
      assert.equals("999k", TokenUsage._humanize(999499))
      assert.equals("1.0M", TokenUsage._humanize(999500))
      assert.equals("1.0M", TokenUsage._humanize(1000000))
    end)
  end)

  describe("section", function()
    it("is a heading at the same level as ### Modified Files", function()
      local acc = TokenUsage.new()
      TokenUsage.record(acc, usage(2, 6000, 82000, 400))

      local section = TokenUsage.section(acc, 150000)

      assert.equals("### Tokens <!-- context=88002 -->", vim.split(section, "\n")[1])
      assert.truthy(section:find("context 88k", 1, true))
    end)

    it("carries the exact context in the heading, since the visible line is rounded", function()
      local acc = TokenUsage.new()
      TokenUsage.record(acc, usage(2, 600, 149000, 0))

      local heading = vim.split(TokenUsage.section(acc, 150000), "\n")[1]

      -- 149,602 rounds to "150k" for reading, which would read back as exactly the threshold
      assert.equals(149602, TokenUsage.parse_context(heading))
      assert.truthy(TokenUsage.section(acc, 150000):find("context 150k", 1, true))
    end)

    it("carries the warning inside the section once the chat is large", function()
      local acc = TokenUsage.new()
      TokenUsage.record(acc, usage(2, 12000, 205000, 900))

      local section = TokenUsage.section(acc, 150000)
      local metrics_at = section:find("context 217k", 1, true)
      local warning_at = section:find("⚠️", 1, true)

      assert.truthy(metrics_at)
      assert.truthy(warning_at)
      assert.is_true(warning_at > metrics_at)
    end)

    it("omits the warning while the chat is still small", function()
      local acc = TokenUsage.new()
      TokenUsage.record(acc, usage(2, 100, 30000, 10))

      assert.is_nil(TokenUsage.section(acc, 150000):find("⚠️", 1, true))
    end)

    it("writes no section at all for a turn with nothing to report", function()
      assert.is_nil(TokenUsage.section(TokenUsage.new(), 150000))
      assert.is_nil(TokenUsage.section(nil, 150000))
    end)
  end)

  describe("warning", function()
    it("says nothing below the threshold and speaks at it", function()
      assert.is_nil(TokenUsage.warning(149999, 150000))
      assert.truthy(TokenUsage.warning(150000, 150000))
    end)

    it("names the current size and the threshold it passed", function()
      local warning = TokenUsage.warning(310000, 150000)

      assert.truthy(warning:find("310k", 1, true))
      assert.truthy(warning:find("150k", 1, true))
      -- `/compact`, not `/summarize`: the latter only opens a floating summary and leaves the
      -- session -- and so the next turn's context -- exactly as it was.
      assert.truthy(warning:find("/compact", 1, true))
      assert.is_nil(warning:find("/summarize", 1, true))
    end)

    it("renders as a blockquote so it cannot be mistaken for the model's own words", function()
      for line in vim.gsplit(TokenUsage.warning(310000, 150000), "\n") do
        assert.equals(">", line:sub(1, 1))
      end
    end)

    it("stays quiet when the threshold is disabled", function()
      assert.is_nil(TokenUsage.warning(900000, 0))
      assert.is_nil(TokenUsage.warning(900000, nil))
    end)
  end)

  describe("parse_context", function()
    it("reads the exact figure out of the heading marker", function()
      local acc = TokenUsage.new()
      TokenUsage.record(acc, { input_tokens = 200000, cache_read_input_tokens = 5431 })

      local heading = vim.split(TokenUsage.section(acc, 150000), "\n")[1]

      assert.equals(205431, TokenUsage.parse_context(heading))
    end)

    it("falls back to the metrics line, for chats written before the marker", function()
      local acc = TokenUsage.new()
      TokenUsage.record(acc, { input_tokens = 200000, cache_read_input_tokens = 5000 })

      assert.equals(205000, TokenUsage.parse_context(TokenUsage.format(acc)))
    end)

    it("reads every magnitude the humanized form uses", function()
      assert.equals(940, TokenUsage.parse_context("context 940 · 1 request · read 0 · new 940"))
      assert.equals(205000, TokenUsage.parse_context("context 205k · 12 requests · read 2.4M · new 12k"))
      assert.equals(1200000, TokenUsage.parse_context("context 1.2M · 30 requests · read 9.9M · new 40k"))
    end)

    it("returns nothing for a line that is not a metrics line", function()
      assert.is_nil(TokenUsage.parse_context("### Tokens"))
      assert.is_nil(TokenUsage.parse_context("the context was large"))
      assert.is_nil(TokenUsage.parse_context(nil))
    end)
  end)
end)
