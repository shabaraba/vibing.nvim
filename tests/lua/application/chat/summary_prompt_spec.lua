-- Gates the `chat_summary` template against the parser that consumes its output. The contract
-- itself is documented where it is enforced: `presentation/chat/modules/summary_inserter.lua`,
-- above `find_summary_section`.
--
-- The example block is fed to the real `insert_or_update` twice rather than matched against copies
-- of the parser's own patterns. A copy of those patterns keeps passing after the parser's
-- terminators change, which is the one drift this spec exists to catch — and it takes two inserts
-- to see it, because a stray `##` in the body only bites on the update path, where
-- `find_summary_section` ends the section early and orphans the tail of the previous summary.

local PromptLoader = require("vibing.core.utils.prompt_loader")
local SummaryInserter = require("vibing.presentation.chat.modules.summary_inserter")
local use_case = require("vibing.application.chat.use_case")

describe("chat_summary prompt", function()
  local template = assert(PromptLoader.load("chat_summary"))
  local example = template:match("```markdown\n(.-)\n```")

  ---@param lines string[]
  ---@param needle string
  ---@return number
  local function occurrences(lines, needle)
    local n = 0
    for _, line in ipairs(lines) do
      if line == needle then
        n = n + 1
      end
    end
    return n
  end

  it("binds the template's variable to what the caller passes", function()
    local prompt, err = use_case._build_summary_prompt({ { role = "user", content = "hello" } })

    assert.is_nil(err)
    assert.is_truthy(prompt:find('<message role="user">\nhello\n</message>', 1, true))
    assert.is_nil(prompt:find("{{", 1, true), "an unsubstituted {{variable}} reached the prompt")
  end)

  it("demonstrates an example the summary inserter keeps whole across a re-run", function()
    assert.is_truthy(example, "no ```markdown example block found in the template")

    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "# Vibing Chat", "", "---" })

    assert.is_true(SummaryInserter.insert_or_update(buf, example), "first insert was rejected")
    assert.is_true(SummaryInserter.insert_or_update(buf, example), "re-insert was rejected")

    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local example_lines = vim.split(example, "\n", { plain = true })
    local tail = example_lines[#example_lines]
    assert.equals(1, occurrences(lines, tail), "the example's tail was orphaned by the update path")

    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("cites the example's own headings in its rules", function()
    local rules = template:match("\n## Rules\n(.*)$")
    assert.is_truthy(rules, "no ## Rules section found in the template")

    local cited = 0
    for heading in rules:gmatch("`(###[^`]*)`") do
      cited = cited + 1
      local msg = ("the rules cite `%s`, which the example does not contain"):format(heading)
      assert.is_truthy(example:find(heading, 1, true), msg)
    end
    assert.is_true(cited > 0, "no `###` heading is cited in the rules")
  end)

  it("keeps the decision block the format exists for", function()
    assert.is_truthy(example:find("#### 決定:", 1, true), "example lost the per-decision block")
    assert.is_truthy(example:find("却下", 1, true), "example lost the rejected-alternatives line")
  end)
end)
