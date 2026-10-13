local References = require("vibing.core.utils.summary_references")
local UseCase = require("vibing.application.chat.use_case")
local Inserter = require("vibing.presentation.chat.modules.summary_inserter")

local cases = {
  {
    "repairs cwd links from qualified references",
    "kintone/project-items#712",
    "- [#712](https://github.com/kintone/virtual-monorepo/issues/712)",
    "- [#712](https://github.com/kintone/project-items/issues/712)",
  },
  {
    "keeps explicit PR paths over shorthand in either order",
    "https://github.com/private/repo/pull/71509 private/repo#71509",
    "- #71509",
    "- [#71509](https://github.com/private/repo/pull/71509)",
  },
  {
    "removes invented links for unresolved numbers",
    "issue #123",
    "- [#123](https://github.com/cwd/repo/issues/123)",
    "- #123",
  },
  {
    "leaves colliding bare numbers unresolved",
    "one/repo#7 two/repo#7",
    "- [#7](https://github.com/one/repo/issues/7)",
    "- #7",
  },
  {
    "resolves qualified labels despite number collisions",
    "one/repo#7 two/repo#7",
    "- two/repo#7",
    "- [two/repo#7](https://github.com/two/repo/issues/7)",
  },
  {
    "does not treat generated qualified names as evidence",
    "issue #7",
    "- [invented/repo#7](https://github.com/invented/repo/issues/7)",
    "- invented/repo#7",
  },
  {
    "splits mismatched issue and PR numbers into separate references",
    "kintone/project-items#711 https://github.com/kintone-private/kintone/pull/69778",
    "- [#711](https://github.com/cwd/repo/pull/69778) 対応",
    "- [#711](https://github.com/kintone/project-items/issues/711) 対応\n- [#69778](https://github.com/kintone-private/kintone/pull/69778)",
  },
  {
    "does not invent the other half of a mismatched link",
    "one/repo#711",
    "- [#711](https://github.com/cwd/repo/pull/69778)",
    "- [#711](https://github.com/one/repo/issues/711)",
  },
  {
    "preserves manually corrected links over transcript destinations",
    "https://github.com/stale/repo/issues/7",
    "- [#7](https://github.com/stale/repo/issues/7)",
    "- [#7](https://github.com/correct/repo/pull/7)",
    "## summary\n- [#7](https://github.com/correct/repo/pull/7)",
  },
  {
    "does not override other qualified repos with an edited bare link",
    "one/repo#7 two/repo#7",
    "- two/repo#7",
    "- [two/repo#7](https://github.com/two/repo/issues/7)\n\n### 🔗 関連\n\n- [one/repo#7](https://github.com/one/repo/issues/7)",
    "## summary\n- [#7](https://github.com/one/repo/issues/7)",
  },
  {
    "does not retain mismatched previous labels as corrections",
    "one/repo#711",
    "- #711",
    "- [#711](https://github.com/one/repo/issues/711)",
    "## summary\n- [#711](https://github.com/wrong/repo/pull/69778)",
  },
  {
    "validates descriptive links too",
    "https://github.com/one/repo/pull/7",
    "- [修正PR](https://github.com/cwd/repo/pull/7)",
    "- [修正PR](https://github.com/one/repo/pull/7)",
  },
  {
    "validates standalone URLs",
    "one/repo#7",
    "- https://github.com/cwd/repo/issues/7",
    "- [#7](https://github.com/one/repo/issues/7)",
  },
  {
    "preserves edited references even when the model omits them",
    "#7",
    "## summary\n- 決定事項",
    "## summary\n- 決定事項\n\n### 🔗 関連\n\n- [correct/repo#7](https://github.com/correct/repo/pull/7)",
    "## summary\n- [#7](https://github.com/correct/repo/pull/7)",
  },
  {
    "rejects a previous link whose qualified repo contradicts the URL",
    "one/repo#7",
    "- #7",
    "- [#7](https://github.com/one/repo/issues/7)",
    "## summary\n- [one/repo#7](https://github.com/wrong/repo/issues/7)",
  },
  {
    "preserves URL fragments from explicit evidence",
    "https://github.com/one/repo/pull/7#discussion_r123",
    "- #7",
    "- [#7](https://github.com/one/repo/pull/7#discussion_r123)",
  },
  {
    "preserves known external forge links without guessing their URL format",
    "https://gitlab.example.com/one/repo/-/merge_requests/7",
    "- [#7](https://gitlab.example.com/one/repo/-/merge_requests/7)",
    "- [#7](https://gitlab.example.com/one/repo/-/merge_requests/7)",
  },
  {
    "preserves unrelated links and code examples",
    "one/repo#7",
    "[docs](https://example.com) `#7`\n~~~~md\n[#7](https://github.com/cwd/repo/issues/7)\n~~~~",
    "[docs](https://example.com) `#7`\n~~~~md\n[#7](https://github.com/cwd/repo/issues/7)\n~~~~",
  },
  {
    "rejects numeric URL prefixes as evidence",
    "https://github.com/one/repo/issues/7invalid",
    "- #7",
    "- #7",
  },
}

describe("summary reference evidence", function()
  for _, case in ipairs(cases) do
    it(case[1], function()
      local refs = References.build({ { content = case[2] } }, case[5])
      assert.equals(case[4], References.normalize(case[3], refs))
    end)
  end

  it("checks real helper output and preserves edits across repeated summaries", function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "# Vibing Chat",
      "",
      "## summary",
      "- [#7](https://github.com/correct/repo/pull/7)",
      "",
      "---",
    })
    local original = package.loaded["vibing"]
    local callback
    package.loaded["vibing"] = {
      get_helper_adapter = function()
        return {
          stream = function(_, _, _, _, done)
            callback = done
          end,
        }
      end,
    }
    local chat = {
      buf = buf,
      is_sending = function()
        return false
      end,
      get_cwd = function()
        return "/unused"
      end,
      extract_conversation = function()
        return { { role = "user", content = "https://github.com/stale/repo/issues/7 #99" } }
      end,
    }
    local ok, err = pcall(function()
      for _ = 1, 2 do
        UseCase.generate_and_insert_summary(chat)
        -- Correct again while the helper is running; completion must read the live summary.
        Inserter.insert_or_update(buf, "## summary\n- [#7](https://github.com/final/repo/pull/7)")
        callback({
          content = "## summary\n- [#7](https://github.com/cwd/repo/issues/7)\n- [#99](https://github.com/cwd/repo/issues/99)",
        })
        assert.equals("## summary\n\n- [#7](https://github.com/final/repo/pull/7)\n- #99", Inserter.extract(buf))
      end
    end)
    package.loaded["vibing"] = original
    vim.api.nvim_buf_delete(buf, { force = true })
    if not ok then
      error(err)
    end
  end)
end)
