-- Tests for vibing.presentation.chat.modules.summary_inserter module

describe("vibing.presentation.chat.modules.summary_inserter", function()
  local SummaryInserter
  local mock_buf_lines = {}
  local mock_buf_valid = true

  before_each(function()
    -- Clear loaded modules
    package.loaded["vibing.presentation.chat.modules.summary_inserter"] = nil
    package.loaded["vibing.core.utils.notify"] = nil

    -- Mock vim APIs
    _G.vim = _G.vim or {}
    _G.vim.api = _G.vim.api or {}
    _G.vim.log = { levels = { WARN = 1, ERROR = 2, INFO = 3 } }
    _G.vim.split = function(str, sep, opts)
      local result = {}
      local pattern = sep
      if opts and opts.plain then
        pattern = sep:gsub("([^%w])", "%%%1")
      end
      for part in (str .. sep):gmatch("(.-)" .. pattern) do
        table.insert(result, part)
      end
      return result
    end
    _G.vim.trim = function(s)
      return s:match("^%s*(.-)%s*$")
    end

    _G.vim.api.nvim_buf_is_valid = function(_)
      return mock_buf_valid
    end

    _G.vim.api.nvim_buf_get_lines = function(_, _, _, _)
      return mock_buf_lines
    end

    _G.vim.api.nvim_buf_set_lines = function(_, start_line, end_line, _, lines)
      -- Simple implementation for testing
      local new_lines = {}
      for i = 1, start_line do
        table.insert(new_lines, mock_buf_lines[i])
      end
      for _, line in ipairs(lines) do
        table.insert(new_lines, line)
      end
      for i = end_line + 1, #mock_buf_lines do
        table.insert(new_lines, mock_buf_lines[i])
      end
      mock_buf_lines = new_lines
    end

    -- Mock notify module
    package.loaded["vibing.core.utils.notify"] = {
      error = function() end,
      warn = function() end,
      info = function() end,
    }

    -- Reset state
    mock_buf_lines = {}
    mock_buf_valid = true

    -- Load the module
    SummaryInserter = require("vibing.presentation.chat.modules.summary_inserter")
  end)

  describe("insert_or_update()", function()
    it("新しいサマリーを正しい位置に挿入できる", function()
      mock_buf_lines = {
        "---",
        "vibing.nvim: true",
        "---",
        "# Vibing Chat",
        "---",
        "## User",
        "Hello",
      }

      local summary = "## summary\n\n### やったこと\n- テスト実行"
      local result = SummaryInserter.insert_or_update(1, summary)

      assert.is_true(result)
      -- Check that summary was inserted after "# Vibing Chat" line
      assert.equals("# Vibing Chat", mock_buf_lines[4])
      assert.equals("", mock_buf_lines[5])
      assert.equals("## summary", mock_buf_lines[6])
    end)

    it("既存のサマリーを更新できる", function()
      mock_buf_lines = {
        "---",
        "vibing.nvim: true",
        "---",
        "# Vibing Chat",
        "",
        "## summary",
        "",
        "### やったこと",
        "- 古い内容",
        "",
        "---",
        "## User",
        "Hello",
      }

      local summary = "## summary\n\n### やったこと\n- 新しい内容"
      local result = SummaryInserter.insert_or_update(1, summary)

      assert.is_true(result)
      -- Verify update happened
      local found_new = false
      for _, line in ipairs(mock_buf_lines) do
        if line:match("新しい内容") then
          found_new = true
        end
        assert.is_nil(line:match("古い内容"))
      end
      assert.is_true(found_new)
    end)

    it("複数の ## セクションがある場合に正しく終了位置を検出できる", function()
      mock_buf_lines = {
        "---",
        "vibing.nvim: true",
        "---",
        "# Vibing Chat",
        "",
        "## summary",
        "### やったこと",
        "- テスト",
        "## another section",
        "some content",
        "---",
        "## User",
        "Hello",
      }

      local summary = "## summary\n\n### やったこと\n- 更新"
      local result = SummaryInserter.insert_or_update(1, summary)

      assert.is_true(result)
      -- Verify "## another section" is preserved
      local found_another = false
      for _, line in ipairs(mock_buf_lines) do
        if line == "## another section" then
          found_another = true
        end
      end
      assert.is_true(found_another)
    end)

    it("フロントマッター内の ## summary を誤検出しない", function()
      mock_buf_lines = {
        "---",
        "vibing.nvim: true",
        "## summary: test",
        "---",
        "# Vibing Chat",
        "---",
        "## User",
        "Hello",
      }

      local summary = "## summary\n\n### やったこと\n- テスト"
      local result = SummaryInserter.insert_or_update(1, summary)

      assert.is_true(result)
      -- Summary should be inserted after "# Vibing Chat", not replace frontmatter content
      assert.equals("## summary: test", mock_buf_lines[3])
    end)

    it("無効なバッファの場合はfalseを返す", function()
      mock_buf_valid = false
      local result = SummaryInserter.insert_or_update(1, "## summary\n- test")
      assert.is_false(result)
    end)

    it("# Vibing Chat が見つからない場合はfalseを返す", function()
      mock_buf_lines = {
        "---",
        "vibing.nvim: true",
        "---",
        "## User",
        "Hello",
      }

      local result = SummaryInserter.insert_or_update(1, "## summary\n- test")
      assert.is_false(result)
    end)

    it("--- セパレータが見つからない場合はfalseを返す", function()
      mock_buf_lines = {
        "---",
        "vibing.nvim: true",
        "---",
        "# Vibing Chat",
        "## User",
        "Hello",
      }

      local result = SummaryInserter.insert_or_update(1, "## summary\n- test")
      assert.is_false(result)
    end)

    it("サマリーが ## summary で始まらない場合はfalseを返す", function()
      mock_buf_lines = {
        "---",
        "vibing.nvim: true",
        "---",
        "# Vibing Chat",
        "---",
        "## User",
        "Hello",
      }

      local result = SummaryInserter.insert_or_update(1, "Invalid summary content")
      assert.is_false(result)
    end)

    it("大文字小文字を区別せずに ## Summary を検出できる", function()
      mock_buf_lines = {
        "---",
        "vibing.nvim: true",
        "---",
        "# Vibing Chat",
        "",
        "## Summary",
        "### やったこと",
        "- 古い内容",
        "---",
        "## User",
        "Hello",
      }

      local summary = "## summary\n\n### やったこと\n- 新しい内容"
      local result = SummaryInserter.insert_or_update(1, summary)

      assert.is_true(result)
    end)

    it("空行のみのサマリーはfalseを返す", function()
      mock_buf_lines = {
        "---",
        "vibing.nvim: true",
        "---",
        "# Vibing Chat",
        "---",
        "## User",
        "Hello",
      }

      local result = SummaryInserter.insert_or_update(1, "\n\n\n")
      assert.is_false(result)
    end)

    it("先頭と末尾の空行をトリミングする", function()
      mock_buf_lines = {
        "---",
        "vibing.nvim: true",
        "---",
        "# Vibing Chat",
        "---",
        "## User",
        "Hello",
      }

      local summary = "\n\n## summary\n\n### やったこと\n- テスト\n\n\n"
      local result = SummaryInserter.insert_or_update(1, summary)

      assert.is_true(result)
      -- First non-empty line should be ## summary
      local summary_found = false
      for _, line in ipairs(mock_buf_lines) do
        if line == "## summary" then
          summary_found = true
          break
        end
      end
      assert.is_true(summary_found)
    end)
  end)
end)
