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

  -- リポジトリはどれも作り物の remote にする。テンプレートの例文（`org/repo`）や、このリポジトリ
  -- 自身の origin を当てにすると、置換が丸ごと壊れてもテストは通ってしまう。cwd を渡さない
  -- 呼び方をテストに残さないのも同じ理由で、そちらは実行環境の本物の origin を読みに行く。
  ---@param remote string|nil nil なら remote 無しの git リポジトリ
  ---@return string dir 使い終わったら呼び出し側が消す
  local function scratch_repo(remote)
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    vim.system({ "git", "init", "-q", dir }):wait()
    if remote then
      vim.system({ "git", "-C", dir, "remote", "add", "origin", remote }):wait()
    end
    return dir
  end

  -- 要約は lightweight 呼び出しでツールを持たないので、リポジトリ URL はプロンプトに載って
  -- いなければモデルには手に入らない。載らなければ issue 番号は素のテキストのままになる。
  ---@param remote string|nil
  ---@return string prompt
  local function prompt_for_remote(remote)
    local dir = scratch_repo(remote)
    local prompt = assert(use_case._build_summary_prompt({ { role = "user", content = "hello" } }, dir))
    vim.fn.delete(dir, "rf")

    assert.is_nil(prompt:find("{{", 1, true), "an unsubstituted {{variable}} reached the prompt")
    return prompt
  end

  it("binds the template's variable to what the caller passes", function()
    local dir = scratch_repo(nil)
    local prompt, err = use_case._build_summary_prompt({ { role = "user", content = "hello" } }, dir)
    vim.fn.delete(dir, "rf")

    assert.is_nil(err)
    assert.is_truthy(prompt:find('<message role="user">\nhello\n</message>', 1, true))
    assert.is_nil(prompt:find("{{", 1, true), "an unsubstituted {{variable}} reached the prompt")
  end)

  it("hands the model the repository url an issue link needs", function()
    local prompt = prompt_for_remote("git@github.com:acme/thing.git")

    assert.is_truthy(prompt:find("[#123](https://github.com/acme/thing/issues/123)", 1, true))
  end)

  -- issue の URL 形は forge ごとに違う（GitLab は `/-/issues/`）。知らない forge で `/issues/` を
  -- 例に出すと、開けないリンクがチャットファイルに残る。
  it("does not invent an issue url shape for a forge it does not know", function()
    local prompt = prompt_for_remote("git@gitlab.example.com:acme/thing.git")

    assert.is_truthy(prompt:find("https://gitlab.example.com/acme/thing", 1, true))
    -- テンプレート側の例文にも `/issues/123` はあるので、ホストまで込みで見ないと空振りする
    assert.is_nil(prompt:find("gitlab.example.com/acme/thing/issues", 1, true))
    assert.is_truthy(prompt:find("issue の URL 形式は不明", 1, true))
  end)

  it("says the repository is unknown rather than dropping the instruction", function()
    local prompt = prompt_for_remote(nil)

    assert.is_truthy(prompt:find("リポジトリ URL は不明", 1, true))
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
