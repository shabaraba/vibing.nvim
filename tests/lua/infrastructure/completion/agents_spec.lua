local Agents = require("vibing.infrastructure.completion.providers.agents")

describe("agents provider frontmatter", function()
  local dir

  ---@param lines string[]
  ---@return string
  local function write_agent(lines)
    local path = dir .. "/agent.md"
    vim.fn.writefile(lines, path)
    return path
  end

  before_each(function()
    dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
  end)

  after_each(function()
    vim.fn.delete(dir, "rf")
  end)

  it("reads a folded block scalar description instead of its header", function()
    local path = write_agent({
      "---",
      "name: boundary-review",
      "description: >-",
      "  First line of the description.",
      "  TRIGGER: second line.",
      "---",
      "",
      "Body.",
    })

    local agent = Agents._parse_agent(path, "my-plugin")

    assert.are.equal("boundary-review", agent.name)
    assert.are.equal("First line of the description. TRIGGER: second line.", agent.description)
  end)

  it("stops a block scalar at the next top-level key", function()
    local path = write_agent({
      "---",
      "description: |",
      "  Literal block.",
      "model: sonnet",
      "name: after-block",
      "---",
    })

    local agent = Agents._parse_agent(path, "my-plugin")

    assert.are.equal("after-block", agent.name)
    assert.are.equal("Literal block.", agent.description)
  end)

  it("still reads a plain single-line description", function()
    local path = write_agent({
      "---",
      "name: plain",
      "description: Does a thing.",
      "---",
    })

    local agent = Agents._parse_agent(path, "my-plugin")

    assert.are.equal("Does a thing.", agent.description)
    assert.are.equal("my-plugin:plain", agent.full_name)
  end)

  it("falls back to the name when the description is missing", function()
    local path = write_agent({ "---", "name: bare", "---" })

    assert.are.equal("bare", Agents._parse_agent(path, "my-plugin").description)
  end)
end)
