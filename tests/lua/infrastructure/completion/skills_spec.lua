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

describe("skills provider CLI command list", function()
  ---@param commands table[]
  ---@return table<string, Vibing.CompletionItem>
  local function by_word(commands)
    local indexed = {}
    for _, item in ipairs(Skills._to_items(commands)) do
      indexed[item.word] = item
    end
    return indexed
  end

  it("keeps a built-in skill the CLI grew after this code was written", function()
    -- The whole point: /design is backed by no file, so nothing here can enumerate it. It has to
    -- survive on the CLI having said so.
    local items = by_word({
      { name = "design", description = "Grant or revoke Claude agent access" },
      { name = "dataviz", description = "Use this skill for any chart." },
    })

    assert.is_truthy(items["design"])
    assert.are.equal("bundled", items["dataviz"].source)
  end)

  it("drops the CLI's terminal-only commands and its internal ones", function()
    local items = by_word({
      { name = "color", description = "Set the prompt bar color for this session" },
      { name = "__remote-workflow", description = "Run the workflow script" },
      { name = "usage", description = "Show session cost" },
      { name = "run", description = "Launch and drive this project's app" },
    })

    assert.is_nil(items["color"])
    assert.is_nil(items["__remote-workflow"])
    assert.is_nil(items["usage"])
    assert.is_truthy(items["run"])
  end)

  it("reads the source from the namespace and the description marker", function()
    local items = by_word({
      { name = "vibing-nvim:vibing-code-tour", description = "Walk the user through a path." },
      { name = "android-dev", description = "Android tooling. (user)" },
      { name = "self-testing", description = "E2E self-testing workflow. (project)" },
    })

    assert.are.equal("plugin", items["vibing-nvim:vibing-code-tour"].source)
    assert.are.equal("vibing-nvim", items["vibing-nvim:vibing-code-tour"].detail)
    assert.are.equal("user", items["android-dev"].source)
    assert.are.equal("project", items["self-testing"].source)
  end)

  it("ignores an entry with no usable name instead of listing a blank one", function()
    local items = Skills._to_items({ { description = "No name" }, { name = "" }, "not a table" })

    assert.are.equal(0, #items)
  end)
end)
