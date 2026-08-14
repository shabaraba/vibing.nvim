local Common = require("vibing.infrastructure.adapter.modules.command_builder_common")

describe("command_builder_common", function()
  describe("resolve_language", function()
    it("prefers the per-request language", function()
      assert.equals("ja", Common.resolve_language({ language = "ja" }, { language = "fr" }))
    end)

    it("accepts config.language as a plain string", function()
      assert.equals("fr", Common.resolve_language({}, { language = "fr" }))
    end)

    it("accepts config.language as a table, preferring default over chat", function()
      assert.equals("de", Common.resolve_language({}, { language = { default = "de", chat = "fr" } }))
      assert.equals("fr", Common.resolve_language({}, { language = { chat = "fr" } }))
    end)

    it("returns nil when nothing is set or the value is not a string", function()
      assert.is_nil(Common.resolve_language({}, {}))
      assert.is_nil(Common.resolve_language({}, { language = {} }))
      assert.is_nil(Common.resolve_language({}, { language = 42 }))
    end)
  end)

  describe("language_instruction", function()
    it("names the language and its code", function()
      assert.equals("Always respond in Japanese (ja).", Common.language_instruction({ language = "ja" }, {}))
    end)

    it("says nothing for English, which is every CLI's own default", function()
      assert.is_nil(Common.language_instruction({ language = "en" }, {}))
    end)

    it("says nothing for a code with no display name", function()
      assert.is_nil(Common.language_instruction({ language = "zz" }, {}))
    end)

    it("says nothing when no language is configured", function()
      assert.is_nil(Common.language_instruction({}, {}))
    end)
  end)

  describe("context_prefix", function()
    it("renders @file: entries with a trailing blank line", function()
      local prefix = Common.context_prefix({ context = { "@file:a.lua", "@file:b/c.lua" } })
      assert.equals("Context file: a.lua\nContext file: b/c.lua\n\n", prefix)
    end)

    it("keeps line ranges, which are part of the reference", function()
      assert.equals("Context file: a.lua:L10-L25\n\n", Common.context_prefix({ context = { "@file:a.lua:L10-L25" } }))
    end)

    it("ignores entries that are not file references", function()
      assert.equals("", Common.context_prefix({ context = { "something else" } }))
    end)

    it("returns an empty string, not nil, when there is no context", function()
      assert.equals("", Common.context_prefix({}))
      assert.equals("", Common.context_prefix({ context = {} }))
    end)
  end)

  describe("binary_resolver", function()
    local original_exepath

    before_each(function()
      original_exepath = vim.fn.exepath
    end)

    after_each(function()
      vim.fn.exepath = original_exepath
    end)

    it("returns the resolved path", function()
      vim.fn.exepath = function()
        return "/usr/local/bin/thing"
      end
      assert.equals("/usr/local/bin/thing", Common.binary_resolver("thing", "missing").resolve())
    end)

    it("looks the binary up once and caches it", function()
      local lookups = 0
      vim.fn.exepath = function()
        lookups = lookups + 1
        return "/usr/local/bin/thing"
      end

      local resolver = Common.binary_resolver("thing", "missing")
      resolver.resolve()
      resolver.resolve()
      assert.equals(1, lookups)
    end)

    it("raises the given message when the binary is absent", function()
      vim.fn.exepath = function()
        return ""
      end
      local ok, err = pcall(Common.binary_resolver("thing", "thing is not installed").resolve)
      assert.is_false(ok)
      assert.is_truthy(tostring(err):find("thing is not installed", 1, true))
    end)

    it("caches nothing on failure, so a later lookup can still succeed", function()
      local found = false
      vim.fn.exepath = function()
        return found and "/usr/local/bin/thing" or ""
      end

      local resolver = Common.binary_resolver("thing", "missing")
      assert.is_false(pcall(resolver.resolve))
      found = true
      assert.equals("/usr/local/bin/thing", resolver.resolve())
    end)

    it("forgets the cached path on reset, which is what the specs need", function()
      vim.fn.exepath = function()
        return "/first"
      end
      local resolver = Common.binary_resolver("thing", "missing")
      assert.equals("/first", resolver.resolve())

      vim.fn.exepath = function()
        return "/second"
      end
      assert.equals("/first", resolver.resolve(), "should still be cached")

      resolver.reset()
      assert.equals("/second", resolver.resolve())
    end)

    it("gives each caller its own cache", function()
      vim.fn.exepath = function(name)
        return "/bin/" .. name
      end
      local a = Common.binary_resolver("alpha", "missing")
      local b = Common.binary_resolver("bravo", "missing")
      assert.equals("/bin/alpha", a.resolve())
      assert.equals("/bin/bravo", b.resolve())
    end)
  end)
end)
