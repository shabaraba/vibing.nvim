local Toml = require("vibing.core.utils.toml")

describe("toml", function()
  describe("is_bare_key", function()
    it("accepts letters, digits, underscore and hyphen", function()
      assert.is_true(Toml.is_bare_key("vibing-nvim"))
      assert.is_true(Toml.is_bare_key("probe_1"))
    end)

    -- The codex `-c` key path is split on `.` and each segment is taken literally, so a name
    -- that would need quoting cannot be expressed at all: `mcp_servers."a.b".command` registers
    -- a server named `"a.b"`, quotes included (codex 0.153).
    it("rejects anything that would need quoting in a key path", function()
      assert.is_false(Toml.is_bare_key("a.b"))
      assert.is_false(Toml.is_bare_key("with space"))
      assert.is_false(Toml.is_bare_key(""))
      assert.is_false(Toml.is_bare_key(nil))
    end)
  end)

  describe("string", function()
    it("quotes and escapes the characters a basic string cannot hold raw", function()
      assert.equals('"a \\"q\\" b\\\\c"', Toml.string('a "q" b\\c'))
    end)

    it("folds newlines and tabs into escapes so the value stays one argv element", function()
      assert.equals('"line\\nnext\\ttab\\r"', Toml.string("line\nnext\ttab\r"))
    end)

    it("escapes other control characters as \\uXXXX", function()
      assert.equals('"\\u0001"', Toml.string("\1"))
    end)

    it("passes multibyte text through untouched", function()
      assert.equals('"日本語 ü"', Toml.string("日本語 ü"))
    end)
  end)

  describe("string_array", function()
    it("renders each entry as a basic string", function()
      assert.equals('["a", "b \\"c\\""]', Toml.string_array({ "a", 'b "c"' }))
    end)

    it("renders an empty list as []", function()
      assert.equals("[]", Toml.string_array({}))
    end)
  end)

  describe("string_table", function()
    it("sorts keys so the output is byte-stable across calls", function()
      assert.equals('{ A = "1", B = "2" }', Toml.string_table({ B = "2", A = "1" }))
    end)

    it("quotes a key that is not bare, since inline-table keys are parsed as TOML", function()
      assert.equals('{ "a.b" = "1" }', Toml.string_table({ ["a.b"] = "1" }))
    end)
  end)
end)
