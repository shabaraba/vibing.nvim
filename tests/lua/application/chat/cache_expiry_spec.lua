-- Tests for the pre-send prompt-cache decision: reading the last turn's end time and context back
-- out of the chat buffer, and the thresholds that decide whether a send is worth confirming.
-- The prompt itself lives in presentation/chat/modules/cache_expiry_prompt.

describe("cache_expiry", function()
  local CacheExpiry = require("vibing.application.chat.cache_expiry")
  local ChatBuffer = require("vibing.presentation.chat.buffer")
  local Config = require("vibing.config")
  local TokenUsage = require("vibing.core.utils.token_usage")

  local original_config_get
  local created_bufs

  before_each(function()
    original_config_get = Config.get
    created_bufs = {}
  end)

  after_each(function()
    Config.get = original_config_get
    for _, bufnr in ipairs(created_bufs) do
      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end
  end)

  --- @param opts table|nil overrides for agent.token_usage
  local function stub_config(opts)
    Config.get = function()
      return {
        agent = {
          token_usage = vim.tbl_extend(
            "force",
            { enabled = true, warn_context = 150000, cache_ttl_sec = 3300 },
            opts or {}
          ),
        },
      }
    end
  end

  --- @param seconds_ago number
  --- @return string
  local function stamp(seconds_ago)
    return os.date("%Y-%m-%d %H:%M:%S", os.time() - seconds_ago)
  end

  --- @param context number
  --- @return string[] the `### Tokens` section as written by token_usage
  local function tokens_section(context)
    local acc = TokenUsage.new()
    TokenUsage.record(acc, { input_tokens = context })
    return vim.split(TokenUsage.section(acc, 150000), "\n", { plain = true })
  end

  --- @param lines string[]
  --- @return table chat_buffer
  local function make_buffer(lines)
    local bufnr = vim.api.nvim_create_buf(false, true)
    table.insert(created_bufs, bufnr)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    return setmetatable({ buf = bufnr, _pending_approval = nil }, ChatBuffer)
  end

  --- A completed turn followed by an unsent message, which is the shape every case here needs.
  --- @param opts {seconds_ago: number, context: number|nil, unsent: string}
  --- @return table chat_buffer
  local function make_chat(opts)
    local lines = {
      "---",
      "vibing.nvim: true",
      "---",
      "",
      string.format("## User <!-- %s -->", stamp(opts.seconds_ago + 60)),
      "",
      "earlier question",
      "",
      string.format("## Assistant <!-- %s -->", stamp(opts.seconds_ago)),
      "",
      "an answer",
      "",
    }
    if opts.context then
      vim.list_extend(lines, tokens_section(opts.context))
    end
    vim.list_extend(lines, { "## User <!-- unsent -->", "", opts.unsent, "" })
    return make_buffer(lines)
  end

  --- The shape that satisfies both conditions; individual tests vary the config, not the chat.
  local EXPIRED = { seconds_ago = 5000, context = 205000, unsent = "next" }

  describe("read_last_turn", function()
    it("reads the last turn's end time and context", function()
      local epoch, context = CacheExpiry.read_last_turn(make_chat(EXPIRED).buf)

      assert.is_number(epoch)
      assert.is_true(math.abs((os.time() - epoch) - 5000) <= 1)
      assert.equals(205000, context)
    end)

    it("returns nothing for a legacy, unstamped Assistant header", function()
      local chat = make_buffer(vim.list_extend({
        "## User <!-- 2026-09-04 10:00:00 -->",
        "earlier",
        "## Assistant",
        "an answer",
      }, tokens_section(205000)))

      assert.is_nil(CacheExpiry.read_last_turn(chat.buf))
    end)

    it("returns nothing when the last turn wrote no Tokens section", function()
      local chat = make_chat({ seconds_ago = 5000, unsent = "next" })

      assert.is_nil(CacheExpiry.read_last_turn(chat.buf))
    end)

    it("looks past a reply that quotes a bare `## Assistant` line", function()
      -- `parse_header`'s legacy branch matches it anywhere at column 0, so stopping at the first
      -- Assistant-looking line from the end would find the quote, get no timestamp, and give up.
      local lines = {
        string.format("## User <!-- %s -->", stamp(5060)),
        "explain the format",
        string.format("## Assistant <!-- %s -->", stamp(5000)),
        "",
        "Sections look like this:",
        "",
        "## Assistant",
        "",
      }
      vim.list_extend(lines, tokens_section(205000))
      vim.list_extend(lines, { "## User <!-- unsent -->", "next" })

      local epoch, context = CacheExpiry.read_last_turn(make_buffer(lines).buf)

      assert.is_number(epoch)
      assert.equals(205000, context)
    end)

    it("does not read a sentence in the reply as the turn's context", function()
      -- The humanized fallback matches any line starting with `context <number>`, and a reply is
      -- free to contain one. Reading it would suppress the prompt on a genuinely large chat.
      local lines = {
        string.format("## User <!-- %s -->", stamp(5060)),
        "how big is it?",
        string.format("## Assistant <!-- %s -->", stamp(5000)),
        "",
        "context 8 items were dropped, so the window is smaller now.",
        "",
      }
      vim.list_extend(lines, tokens_section(205000))
      vim.list_extend(lines, { "## User <!-- unsent -->", "next" })

      local _, context = CacheExpiry.read_last_turn(make_buffer(lines).buf)

      assert.equals(205000, context)
    end)

    it("does not borrow a Tokens section from an earlier turn", function()
      -- A backend that reports no usage (codex/grok) must not read as "still 205k".
      local lines = {
        string.format("## User <!-- %s -->", stamp(9000)),
        "first",
        string.format("## Assistant <!-- %s -->", stamp(8000)),
        "reply",
      }
      vim.list_extend(lines, tokens_section(205000))
      vim.list_extend(lines, {
        string.format("## User <!-- %s -->", stamp(5000)),
        "second",
        string.format("## Assistant <!-- %s -->", stamp(4000)),
        "reply",
        "",
        "## User <!-- unsent -->",
        "next",
      })

      assert.is_nil(CacheExpiry.read_last_turn(make_buffer(lines).buf))
    end)
  end)

  describe("evaluate", function()
    it("asks when the cache has expired and the context is large", function()
      stub_config()

      local decision = CacheExpiry.evaluate(make_chat(EXPIRED))

      assert.is_not_nil(decision)
      assert.equals(205000, decision.context)
      assert.is_true(decision.elapsed_sec >= 5000)
    end)

    it("stays quiet while the cache is still warm", function()
      stub_config()
      local chat = make_chat({ seconds_ago = 600, context = 205000, unsent = "next" })

      assert.is_nil(CacheExpiry.evaluate(chat))
    end)

    it("stays quiet for a chat below the context threshold", function()
      stub_config()
      local chat = make_chat({ seconds_ago = 5000, context = 40000, unsent = "next" })

      assert.is_nil(CacheExpiry.evaluate(chat))
    end)

    it("is disabled by cache_ttl_sec = 0", function()
      stub_config({ cache_ttl_sec = 0 })

      assert.is_nil(CacheExpiry.evaluate(make_chat(EXPIRED)))
    end)

    it("is disabled by warn_context = 0, which already means 'no warning'", function()
      stub_config({ warn_context = 0 })

      assert.is_nil(CacheExpiry.evaluate(make_chat(EXPIRED)))
    end)

    it("is disabled with the rest of the token usage display", function()
      stub_config({ enabled = false })

      assert.is_nil(CacheExpiry.evaluate(make_chat(EXPIRED)))
    end)

    it("falls back to the shipped defaults rather than switching itself off", function()
      Config.get = function()
        return { agent = { token_usage = { enabled = true } } }
      end
      local chat = make_chat({
        seconds_ago = TokenUsage.DEFAULT_CACHE_TTL_SEC + 100,
        context = TokenUsage.DEFAULT_WARN_CONTEXT + 1000,
        unsent = "next",
      })

      assert.is_not_nil(CacheExpiry.evaluate(chat))
    end)

    it("never delays a slash command", function()
      stub_config()
      local chat = make_chat({ seconds_ago = 5000, context = 205000, unsent = "/summarize" })

      assert.is_nil(CacheExpiry.evaluate(chat))
    end)

    it("never delays a reply to a pending approval prompt", function()
      stub_config()
      local chat = make_chat({
        seconds_ago = 5000,
        context = 205000,
        unsent = "1. allow_once - Allow this execution only",
      })
      chat._pending_approval = { tool = "Bash" }

      assert.is_nil(CacheExpiry.evaluate(chat))
    end)

    it("stays quiet while a request is already in flight", function()
      stub_config()
      local chat = make_chat(EXPIRED)
      chat._is_sending = true

      assert.is_nil(CacheExpiry.evaluate(chat))
    end)
  end)
end)
