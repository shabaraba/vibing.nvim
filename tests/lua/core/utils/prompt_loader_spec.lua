-- プロンプトの読み込みは、プラグインがどのディレクトリ名で置かれていても通らなければならない。
--
-- 元の実装は runtimepath から「`vibing.nvim` という名前で終わるエントリ」を探していた。これは
-- インストールの仕方に依存する: git worktree（`.vibing/worktrees/<branch>/`）や任意の名前での
-- clone では一致せず、`prompts/` が読めないので `:VibingSummarize` とタイトル生成が丸ごと
-- 失敗する。実際、このリポジトリの worktree では summary 系のspecが9件落ちていた。

local PromptLoader = require("vibing.core.utils.prompt_loader")

describe("PromptLoader.load", function()
  it("loads a bundled prompt", function()
    local content, err = PromptLoader.load("chat_summary")

    assert.is_nil(err)
    assert.is_truthy(content)
  end)

  it("finds the prompts directory with no runtimepath entry named vibing.nvim", function()
    local original = vim.o.runtimepath

    local kept = {}
    for _, path in ipairs(vim.api.nvim_list_runtime_paths()) do
      if not path:match("vibing%.nvim/?$") then
        table.insert(kept, path)
      end
    end
    vim.o.runtimepath = table.concat(kept, ",")

    local content, err = PromptLoader.load("chat_summary")
    vim.o.runtimepath = original

    assert.is_nil(err)
    assert.is_truthy(content)
  end)

  it("substitutes template variables", function()
    local content = assert(PromptLoader.load("chat_summary", {
      conversation = "MARKER-CONVERSATION",
      repository_instruction = "MARKER-REPO",
    }))

    assert.is_truthy(content:find("MARKER-CONVERSATION", 1, true))
    assert.is_nil(content:find("{{conversation}}", 1, true))
  end)

  it("reports a missing prompt instead of returning empty content", function()
    local content, err = PromptLoader.load("no_such_prompt_here")

    assert.is_nil(content)
    assert.is_truthy(err)
  end)
end)
