local Vocabulary = require("vibing.infrastructure.adapter.modules.opencode_tool_vocabulary")

describe("opencode_tool_vocabulary", function()
  after_each(function()
    Vocabulary.set_mcp_servers({})
  end)

  describe("to_canonical", function()
    -- OpenCode names an MCP tool `<server>_<tool>` and a server name may contain `_`. Splitting at
    -- the first one would turn `my_server_list` into `mcp__my__server_list`, which a rule written
    -- against `mcp__my_server__list` never matches.
    it("uses a configured server name as the prefix, underscores included", function()
      Vocabulary.set_mcp_servers({ "my_server" })
      assert.equals("mcp__my_server__list", Vocabulary.to_canonical("my_server_list"))
    end)

    it("prefers the longest configured server name", function()
      Vocabulary.set_mcp_servers({ "my", "my_server" })
      assert.equals("mcp__my_server__list", Vocabulary.to_canonical("my_server_list"))
    end)

    it("falls back to the first underscore when no configured server matches", function()
      Vocabulary.set_mcp_servers({})
      assert.equals("mcp__my__server_list", Vocabulary.to_canonical("my_server_list"))
    end)

    it("leaves OpenCode's own namespaced tools alone", function()
      assert.is_nil(Vocabulary.to_canonical("opencode_run"))
      assert.is_nil(Vocabulary.to_canonical("experimental_tool"))
    end)
  end)
end)
