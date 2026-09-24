---@diagnostic disable: undefined-field
local Vocabulary = require("vibing.infrastructure.adapter.modules.pi_tool_vocabulary")

describe("pi_tool_vocabulary", function()
  describe("to_canonical", function()
    it("maps every built-in tool pi --help lists", function()
      -- The eight names are Pi's whole built-in set. An unmapped one reaches `can_use_tool` as its
      -- raw lowercase spelling, matches nothing in `permissions.allow`, and resolves to `ask` --
      -- while every rule the user wrote against the canonical name misses it.
      assert.equals("Bash", Vocabulary.to_canonical("bash"))
      assert.equals("Bash", Vocabulary.to_canonical("powershell"))
      assert.equals("Read", Vocabulary.to_canonical("read"))
      assert.equals("Edit", Vocabulary.to_canonical("edit"))
      assert.equals("Write", Vocabulary.to_canonical("write"))
      assert.equals("Grep", Vocabulary.to_canonical("grep"))
      assert.equals("Glob", Vocabulary.to_canonical("find"))
      assert.equals("Glob", Vocabulary.to_canonical("ls"))
    end)

    it("maps powershell onto Bash, so a Bash deny rule reaches it", function()
      -- Same schema and same risk as bash. Stated separately because it is the mapping that looks
      -- optional and is not: on Windows it is the shell.
      assert.equals(Vocabulary.to_canonical("bash"), Vocabulary.to_canonical("powershell"))
    end)

    it("maps the two web tools vibing.nvim adds to pi", function()
      -- Pi ships no web tool at all; `pi-extension/src/index.ts` registers these. Unmapped, a
      -- `WebFetch` deny rule -- and the fact that neither tool is in `DEFAULT_ALLOWED_TOOLS`
      -- because both are external communication -- would apply to every backend except the one
      -- where vibing.nvim wrote the tool itself.
      assert.equals("WebFetch", Vocabulary.to_canonical("web_fetch"))
      assert.equals("WebSearch", Vocabulary.to_canonical("web_search"))
    end)

    it("spells them the way the other backends' vocabularies do", function()
      -- The name is vibing.nvim's own choice here, so nothing but this forces it to agree. Picking
      -- a different one would work and would quietly make Pi the exception in every rule example.
      local Copilot = require("vibing.infrastructure.adapter.modules.copilot_tool_vocabulary")
      assert.equals(Copilot.to_canonical("web_fetch"), Vocabulary.to_canonical("web_fetch"))
      assert.equals(Copilot.to_canonical("web_search"), Vocabulary.to_canonical("web_search"))
    end)

    it("returns nil for a tool it does not know, rather than guessing", function()
      assert.is_nil(Vocabulary.to_canonical("some_extension_tool"))
    end)
  end)

  describe("normalize_payload", function()
    it("lifts pi's toolName/input into tool_name/tool_input", function()
      -- `input`, not grok's `toolInput`. Reading grok's key here would leave tool_input empty and
      -- every granular rule would see no arguments at all.
      local out = Vocabulary.normalize_payload({ toolName = "bash", input = { command = "ls" } })
      assert.equals("bash", out.tool_name)
      assert.same({ command = "ls" }, out.tool_input)
    end)

    it("gives tool_input an empty table when pi sent no input", function()
      local out = Vocabulary.normalize_payload({ toolName = "ls" })
      assert.same({}, out.tool_input)
    end)

    it("never mutates the payload it was given", function()
      -- The same table renders the approval UI.
      local original = { toolName = "bash", input = { command = "ls" } }
      Vocabulary.normalize_payload(original)
      assert.is_nil(original.tool_name)
    end)

    it("leaves an already-canonical payload alone", function()
      local original = { tool_name = "Bash", tool_input = { command = "ls" } }
      assert.equals(original, Vocabulary.normalize_payload(original))
    end)

    it("leaves a payload with neither spelling alone", function()
      local original = { something = "else" }
      assert.equals(original, Vocabulary.normalize_payload(original))
    end)
  end)

  describe("normalize_input", function()
    it("lifts pi's `path` into file_path, which is what paths rules read", function()
      local out = Vocabulary.normalize_input({ path = "lua/a.lua" })
      assert.equals("lua/a.lua", out.file_path)
    end)

    it("keeps the original key as well, since the UI renders the raw input", function()
      local out = Vocabulary.normalize_input({ path = "lua/a.lua" })
      assert.equals("lua/a.lua", out.path)
    end)

    it("does not overwrite a file_path that is already there", function()
      local out = Vocabulary.normalize_input({ file_path = "kept.lua", path = "other.lua" })
      assert.equals("kept.lua", out.file_path)
    end)

    it("never mutates the input it was given", function()
      local original = { path = "lua/a.lua" }
      Vocabulary.normalize_input(original)
      assert.is_nil(original.file_path)
    end)

    it("leaves an input with no path alone", function()
      local original = { command = "ls" }
      assert.equals(original, Vocabulary.normalize_input(original))
    end)
  end)
end)
