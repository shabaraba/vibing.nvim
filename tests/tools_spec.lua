---@diagnostic disable: undefined-field
describe("vibing.constants.tools", function()
  local tools

  before_each(function()
    tools = require("vibing.constants.tools")
  end)

  describe("validate_tool", function()
    it("validates basic tool names", function()
      assert.equal("Read", tools.validate_tool("read"))
      assert.equal("Read", tools.validate_tool("Read"))
      assert.equal("Bash", tools.validate_tool("bash"))
      assert.equal("Bash", tools.validate_tool("Bash"))
      assert.equal("Edit", tools.validate_tool("edit"))
      assert.equal("Write", tools.validate_tool("write"))
      assert.equal("Glob", tools.validate_tool("glob"))
      assert.equal("Grep", tools.validate_tool("grep"))
      assert.equal("WebSearch", tools.validate_tool("websearch"))
      assert.equal("WebFetch", tools.validate_tool("webfetch"))
      assert.equal("Skill", tools.validate_tool("skill"))
      assert.equal("Skill", tools.validate_tool("Skill"))
    end)

    it("returns nil for invalid tool names", function()
      assert.is_nil(tools.validate_tool("invalid"))
      assert.is_nil(tools.validate_tool("NotATool"))
      assert.is_nil(tools.validate_tool(""))
    end)

    it("validates granular Bash patterns with wildcards", function()
      assert.equal("Bash(npm:*)", tools.validate_tool("Bash(npm:*)"))
      assert.equal("Bash(npm:*)", tools.validate_tool("bash(npm:*)"))
      assert.equal("Bash(git:*)", tools.validate_tool("Bash(git:*)"))
    end)

    it("validates granular Bash patterns with exact commands", function()
      assert.equal("Bash(npm install)", tools.validate_tool("Bash(npm install)"))
      assert.equal("Bash(npm install)", tools.validate_tool("bash(npm install)"))
      assert.equal("Bash(git commit)", tools.validate_tool("Bash(git commit)"))
      assert.equal("Bash(ls -la)", tools.validate_tool("Bash(ls -la)"))
    end)

    it("validates granular patterns for file operations", function()
      assert.equal("Read(src/**/*.ts)", tools.validate_tool("Read(src/**/*.ts)"))
      assert.equal("Read(src/**/*.ts)", tools.validate_tool("read(src/**/*.ts)"))
      assert.equal("Write(test/**/*.js)", tools.validate_tool("Write(test/**/*.js)"))
      assert.equal("Edit(*.md)", tools.validate_tool("Edit(*.md)"))
    end)

    it("validates granular patterns for web tools", function()
      assert.equal("Webfetch(github.com)", tools.validate_tool("Webfetch(github.com)"))
      assert.equal("Webfetch(github.com)", tools.validate_tool("webfetch(github.com)"))
      assert.equal("Websearch(*.npmjs.com)", tools.validate_tool("Websearch(*.npmjs.com)"))
    end)

    it("validates granular patterns for search tools", function()
      assert.equal("Glob(*.test.js)", tools.validate_tool("Glob(*.test.js)"))
      assert.equal("Grep(TODO|FIXME)", tools.validate_tool("Grep(TODO|FIXME)"))
    end)

    it("normalizes tool name capitalization in patterns", function()
      -- Tool name is capitalized, pattern is preserved
      assert.equal("Bash(npm install)", tools.validate_tool("bash(npm install)"))
      assert.equal("Read(SRC/**/*.TS)", tools.validate_tool("read(SRC/**/*.TS)"))
      assert.equal("Webfetch(GitHub.com)", tools.validate_tool("webfetch(GitHub.com)"))
    end)

    it("rejects invalid Bash patterns", function()
      -- Missing closing parenthesis
      assert.is_nil(tools.validate_tool("Bash(npm"))
      -- Missing opening parenthesis
      assert.is_nil(tools.validate_tool("Bashnpm)"))
      -- Empty pattern
      assert.is_nil(tools.validate_tool("Bash()"))
    end)
  end)
end)
