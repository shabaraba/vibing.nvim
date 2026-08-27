local Skills = require("vibing.infrastructure.completion.providers.skills")

describe("skills provider frontmatter", function()
  local root

  ---Write `lines` as `<root>/<skill_name>/SKILL.md` and return its path.
  ---@param skill_name string
  ---@param lines string[]
  ---@return string
  local function write_skill(skill_name, lines)
    local dir = root .. "/" .. skill_name
    vim.fn.mkdir(dir, "p")
    local path = dir .. "/SKILL.md"
    vim.fn.writefile(lines, path)
    return path
  end

  before_each(function()
    root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")
  end)

  after_each(function()
    vim.fn.delete(root, "rf")
  end)

  it("describes a local skill by its frontmatter, not the body heading", function()
    -- The `/` picker used to show "思考整理" here while `list-commands` showed the frontmatter
    -- for a plugin skill, so the same menu described two skills from two different sources.
    local path = write_skill("thought-clarification", {
      "---",
      "name: thought-clarification",
      "description: >-",
      "  漠然とした課題感を言語化する。",
      "  TRIGGER: 「モヤモヤを整理したい」。",
      "---",
      "",
      "# 思考整理（Thought Clarification）",
    })

    local skill = Skills._parse_skill(path)

    assert.are.equal("thought-clarification", skill.name)
    assert.are.equal("漠然とした課題感を言語化する。 TRIGGER: 「モヤモヤを整理したい」。", skill.description)
  end)

  it("falls back to the body heading when no description is declared", function()
    local path = write_skill("headed", { "---", "name: headed", "---", "", "# A Heading" })

    assert.are.equal("A Heading", Skills._parse_skill(path).description)
  end)

  it("falls back to the directory name when there is neither", function()
    local path = write_skill("bare", { "Body with no frontmatter and no heading." })

    assert.are.equal("bare", Skills._parse_skill(path).description)
  end)

  it("still honours user-invocable: false", function()
    local path = write_skill("hidden", {
      "---",
      "name: hidden",
      "description: |",
      "  Literal block.",
      "user-invocable: false",
      "---",
    })

    assert.is_nil(Skills._parse_skill(path))
  end)

  it("returns nil for a missing file", function()
    assert.is_nil(Skills._parse_skill(root .. "/absent/SKILL.md"))
  end)
end)
