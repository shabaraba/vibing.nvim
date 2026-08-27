local YamlFrontmatter = require("vibing.core.utils.yaml_frontmatter")

describe("yaml_frontmatter", function()
  it("reads a plain scalar", function()
    local lines = { "---", "name: plain", "description: Does a thing.", "---", "", "# Body" }

    assert.are.equal("plain", YamlFrontmatter.read(lines, "name"))
    assert.are.equal("Does a thing.", YamlFrontmatter.read(lines, "description"))
  end)

  it("folds a block scalar instead of returning its header", function()
    local lines = {
      "---",
      "description: >-",
      "  First line of the description.",
      "  TRIGGER: second line.",
      "---",
    }

    assert.are.equal(
      "First line of the description. TRIGGER: second line.",
      YamlFrontmatter.read(lines, "description")
    )
  end)

  it("accepts every block header form", function()
    for _, header in ipairs({ "|", ">", "|-", ">-", "|+", ">2", ">-2", "|2-" }) do
      local lines = { "---", "description: " .. header, "  Text.", "---" }
      assert.are.equal("Text.", YamlFrontmatter.read(lines, "description"), header)
    end
  end)

  it("ends a block at the next top-level key", function()
    local lines = {
      "---",
      "description: |",
      "  Literal block.",
      "model: sonnet",
      "---",
    }

    assert.are.equal("Literal block.", YamlFrontmatter.read(lines, "description"))
    assert.are.equal("sonnet", YamlFrontmatter.read(lines, "model"))
  end)

  it("reads a dashed key", function()
    local lines = { "---", "user-invocable: false", "---" }

    assert.are.equal("false", YamlFrontmatter.read(lines, "user-invocable"))
  end)

  it("ignores a key nested under another one", function()
    local lines = { "---", "metadata:", "  description: nested", "---" }

    assert.is_nil(YamlFrontmatter.read(lines, "description"))
  end)

  it("stops at the closing delimiter", function()
    local lines = { "---", "name: real", "---", "", "description: in the body" }

    assert.is_nil(YamlFrontmatter.read(lines, "description"))
  end)

  it("returns nil for an absent key, an empty value, or no frontmatter", function()
    assert.is_nil(YamlFrontmatter.read({ "---", "name: x", "---" }, "description"))
    assert.is_nil(YamlFrontmatter.read({ "---", "description:", "---" }, "description"))
    assert.is_nil(YamlFrontmatter.read({ "# Just a heading" }, "description"))
    assert.is_nil(YamlFrontmatter.read({}, "description"))
  end)
end)
