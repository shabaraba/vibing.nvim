-- How the provider combines what a CLI says with what it finds on disk, per backend. The probe is
-- replaced (what is pinned is the merge, not the protocols), and the skill root is a real directory
-- so the scan side is the real code.

local fetches = {}

package.loaded["vibing.infrastructure.completion.command_probe"] = {
  fetch = function(_, opts, callback)
    table.insert(fetches, { opts = opts, callback = callback })
    return true
  end,
  is_known = function()
    return true
  end,
}

local Skills = require("vibing.infrastructure.completion.providers.skills")
local Cache = require("vibing.infrastructure.completion.providers.command_probe_cache")

local ROOT = vim.fn.tempname()
vim.fn.mkdir(ROOT .. "/ci-gates", "p")
vim.fn.writefile({ "---", "name: ci-gates", "description: from disk", "---" }, ROOT .. "/ci-gates/SKILL.md")

---@param authoritative boolean
---@return Vibing.SkillSources
local function sources(authoritative)
  return {
    probe = { protocol = "acp", args = { "acp" }, authoritative = authoritative },
    dirs = { { path = ROOT, source = "project" } },
  }
end

---Let the CLI answer for `agent`.
---@param agent string
---@param src Vibing.SkillSources
---@param commands Vibing.CliCommand[]
local function answer(agent, src, commands)
  Cache.start(agent, src.probe, function() end)
  fetches[#fetches].callback(commands)
end

---@param items Vibing.CompletionItem[]
---@return table<string, Vibing.CompletionItem>
local function by_word(items)
  local indexed = {}
  for _, item in ipairs(items) do
    indexed[item.word] = item
  end
  return indexed
end

describe("skills provider merge", function()
  before_each(function()
    fetches = {}
    Skills.clear_cache()
  end)

  it("offers the skills no directory holds, once the CLI has answered", function()
    local src = sources(false)
    answer("commandcode", src, { { name = "loop", description = "Run on an interval" } })

    local items = by_word(Skills._scan_skills("commandcode", src))

    assert.is_truthy(items["loop"])
    assert.equals("bundled", items["loop"].source)
    assert.is_truthy(items["ci-gates"])
  end)

  it("lets the directory scan describe a skill when the CLI only reports names", function()
    local src = sources(false)
    answer("commandcode", src, { { name = "ci-gates", description = "from the cli" } })

    local item = by_word(Skills._scan_skills("commandcode", src))["ci-gates"]

    assert.equals("project", item.source)
    assert.equals("from disk", item.description)
  end)

  it("lets an authoritative CLI describe a skill over the directory scan", function()
    local src = sources(true)
    answer("claude", src, { { name = "ci-gates", description = "from the cli" } })

    local item = by_word(Skills._scan_skills("claude", src))["ci-gates"]

    assert.equals("from the cli", item.description)
  end)

  it("starts the probe for the backend asked about and no other", function()
    Skills._scan_skills("codex", sources(false))

    assert.equals(1, #fetches)
    assert.equals("codex", fetches[1].opts.agent)
  end)

  it("keeps one backend's answer out of another backend's menu", function()
    local src = sources(false)
    answer("claude", src, { { name = "design" } })

    assert.is_nil(by_word(Skills._scan_skills("commandcode", src))["design"])
  end)

  describe("peek_cli_commands", function()
    local original_sources = Skills._sources

    after_each(function()
      Skills._sources = original_sources
    end)

    ---@param agent string
    ---@param src Vibing.SkillSources
    local function as_current_chat(agent, src)
      Skills._sources = function()
        return agent, src
      end
    end

    it("reads the current chat's backend, with that backend's hidden commands removed", function()
      local src = sources(false)
      src.probe.hide = { "color" }
      answer("codex", src, { { name = "imagegen" }, { name = "color" } })
      answer("claude", src, { { name = "design" } })
      as_current_chat("codex", src)

      local words = vim.tbl_map(function(item)
        return item.word
      end, Skills.peek_cli_commands())

      assert.same({ "imagegen" }, words)
    end)

    it("never starts a probe, because a keypress on a path fragment must not spawn a CLI", function()
      local src = sources(false)
      as_current_chat("codex", src)

      assert.same({}, Skills.peek_cli_commands())
      assert.equals(0, #fetches)
    end)

    it("is empty for a backend that declares no probe", function()
      answer("claude", sources(false), { { name = "design" } })
      as_current_chat("claude", {})

      assert.same({}, Skills.peek_cli_commands())
    end)
  end)

  describe("preload_buffer", function()
    ---@param agent string?
    ---@return integer bufnr
    local function chat_buffer(agent)
      local bufnr = vim.api.nvim_create_buf(false, true)
      local lines = { "---", "vibing.nvim: true" }
      if agent then
        table.insert(lines, "agent: " .. agent)
      end
      vim.list_extend(lines, { "---", "", "## User <!-- unsent -->", "" })
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
      return bufnr
    end

    it("warms the backend the chat's own frontmatter names, not the current chat's", function()
      -- The current buffer is a different, unrelated one: the answer must come from the buffer
      -- that was set up.
      Skills.preload_buffer(chat_buffer("codex"))

      assert.equals(1, #fetches)
      assert.equals("codex", fetches[1].opts.agent)
    end)

    it("falls back to the default backend when the frontmatter names none", function()
      Skills.preload_buffer(chat_buffer(nil))

      assert.equals(1, #fetches)
      assert.equals(require("vibing.core.constants.agents").DEFAULT, fetches[1].opts.agent)
    end)

    it("starts nothing for a backend that declares no probe", function()
      Skills.preload_buffer(chat_buffer("grok"))

      assert.equals(0, #fetches)
    end)

    it("runs when a chat buffer is set up for completion", function()
      require("vibing.application.completion").setup_buffer(chat_buffer("codex"))

      assert.equals(1, #fetches)
      assert.equals("codex", fetches[1].opts.agent)
    end)

    it("does not start a second probe when the buffer is set up again", function()
      local bufnr = chat_buffer("codex")
      Skills.preload_buffer(bufnr)
      Skills.preload_buffer(bufnr)

      assert.equals(1, #fetches)
    end)
  end)

  it("reports a backend as loading until its own probe answers", function()
    local src = sources(false)
    answer("claude", src, { { name = "design" } })

    assert.is_false(Skills.is_preloading(src, "claude"))
    assert.is_true(Skills.is_preloading(src, "codex"))
    assert.is_false(Skills.is_preloading({}, "codex"))
  end)
end)
