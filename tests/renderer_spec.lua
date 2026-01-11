-- Tests for vibing.presentation.chat.modules.renderer module

describe("vibing.presentation.chat.modules.renderer", function()
  local Renderer
  local mock_buf
  local mock_win

  before_each(function()
    -- Clear loaded modules
    package.loaded["vibing.presentation.chat.modules.renderer"] = nil
    package.loaded["vibing.utils.timestamp"] = nil

    Renderer = require("vibing.presentation.chat.modules.renderer")

    -- Create mock buffer and window
    mock_buf = vim.api.nvim_create_buf(false, true)
    mock_win = nil -- Window is optional for most tests
  end)

  after_each(function()
    -- Cleanup mock buffer
    if mock_buf and vim.api.nvim_buf_is_valid(mock_buf) then
      vim.api.nvim_buf_delete(mock_buf, { force = true })
    end
  end)

  describe("addUserSection", function()
    describe("with pendingChoices", function()
      it("should insert numbered list for single-select questions (multiSelect=false)", function()
        -- Setup
        local pendingChoices = {
          {
            question = "Which database?",
            header = "Database",
            multiSelect = false,
            options = {
              { label = "PostgreSQL", description = "Full-featured" },
              { label = "MySQL", description = "Popular" },
              { label = "SQLite", description = "Lightweight" },
            },
          },
        }

        -- Execute
        Renderer.addUserSection(mock_buf, mock_win, pendingChoices)

        -- Verify
        local lines = vim.api.nvim_buf_get_lines(mock_buf, 0, -1, false)

        -- Find the choice lines (should be numbered)
        local foundNumbered = false
        for _, line in ipairs(lines) do
          if line:match("^1%. PostgreSQL") then
            foundNumbered = true
          end
        end

        assert.is_true(foundNumbered, "Should contain numbered list item '1. PostgreSQL'")

        -- Verify all three options are numbered
        local hasOption1 = false
        local hasOption2 = false
        local hasOption3 = false
        for _, line in ipairs(lines) do
          if line:match("^1%. PostgreSQL") then hasOption1 = true end
          if line:match("^2%. MySQL") then hasOption2 = true end
          if line:match("^3%. SQLite") then hasOption3 = true end
        end

        assert.is_true(hasOption1, "Should have option 1")
        assert.is_true(hasOption2, "Should have option 2")
        assert.is_true(hasOption3, "Should have option 3")
      end)

      it("should insert bullet list for multi-select questions (multiSelect=true)", function()
        -- Setup
        local pendingChoices = {
          {
            question = "Which features?",
            header = "Features",
            multiSelect = true,
            options = {
              { label = "Authentication", description = "User auth" },
              { label = "Logging", description = "Event logging" },
              { label = "Caching", description = "Response cache" },
            },
          },
        }

        -- Execute
        Renderer.addUserSection(mock_buf, mock_win, pendingChoices)

        -- Verify
        local lines = vim.api.nvim_buf_get_lines(mock_buf, 0, -1, false)

        -- Find the choice lines (should be bulleted)
        local foundBullet = false
        for _, line in ipairs(lines) do
          if line:match("^%- Authentication") then
            foundBullet = true
          end
        end

        assert.is_true(foundBullet, "Should contain bullet list item '- Authentication'")

        -- Verify all three options are bulleted
        local hasOption1 = false
        local hasOption2 = false
        local hasOption3 = false
        for _, line in ipairs(lines) do
          if line:match("^%- Authentication") then hasOption1 = true end
          if line:match("^%- Logging") then hasOption2 = true end
          if line:match("^%- Caching") then hasOption3 = true end
        end

        assert.is_true(hasOption1, "Should have option 1")
        assert.is_true(hasOption2, "Should have option 2")
        assert.is_true(hasOption3, "Should have option 3")
      end)

      it("should include option descriptions with proper indentation", function()
        -- Setup
        local pendingChoices = {
          {
            question = "Which database?",
            header = "Database",
            multiSelect = false,
            options = {
              { label = "PostgreSQL", description = "Full-featured, ACID compliant" },
            },
          },
        }

        -- Execute
        Renderer.addUserSection(mock_buf, mock_win, pendingChoices)

        -- Verify
        local lines = vim.api.nvim_buf_get_lines(mock_buf, 0, -1, false)

        local foundDescription = false
        for _, line in ipairs(lines) do
          if line:match("^  Full%-featured, ACID compliant") then
            foundDescription = true
          end
        end

        assert.is_true(foundDescription, "Should contain indented description")
      end)

      it("should handle multiple questions", function()
        -- Setup
        local pendingChoices = {
          {
            question = "Which database?",
            header = "Database",
            multiSelect = false,
            options = {
              { label = "PostgreSQL" },
              { label = "MySQL" },
            },
          },
          {
            question = "Which features?",
            header = "Features",
            multiSelect = true,
            options = {
              { label = "Auth" },
              { label = "Logging" },
            },
          },
        }

        -- Execute
        Renderer.addUserSection(mock_buf, mock_win, pendingChoices)

        -- Verify
        local lines = vim.api.nvim_buf_get_lines(mock_buf, 0, -1, false)

        -- First question should be numbered
        local hasNumbered = false
        -- Second question should be bulleted
        local hasBulleted = false

        for _, line in ipairs(lines) do
          if line:match("^1%. PostgreSQL") then hasNumbered = true end
          if line:match("^%- Auth") then hasBulleted = true end
        end

        assert.is_true(hasNumbered, "Should have numbered list for first question")
        assert.is_true(hasBulleted, "Should have bullet list for second question")
      end)

      it("should handle edge case when multiSelect is nil (defaults to numbered list)", function()
        -- Setup: multiSelect not specified (nil)
        local pendingChoices = {
          {
            question = "Which option?",
            header = "Option",
            -- multiSelect is nil (not specified)
            options = {
              { label = "Option A" },
              { label = "Option B" },
            },
          },
        }

        -- Execute
        Renderer.addUserSection(mock_buf, mock_win, pendingChoices)

        -- Verify: should default to numbered list (not q.multiSelect = true)
        local lines = vim.api.nvim_buf_get_lines(mock_buf, 0, -1, false)

        local foundNumbered = false
        for _, line in ipairs(lines) do
          if line:match("^1%. Option A") then
            foundNumbered = true
          end
        end

        assert.is_true(foundNumbered, "Should default to numbered list when multiSelect is nil")
      end)
    end)

    describe("without pendingChoices", function()
      it("should create user section without choices", function()
        -- Execute
        Renderer.addUserSection(mock_buf, mock_win, nil)

        -- Verify
        local lines = vim.api.nvim_buf_get_lines(mock_buf, 0, -1, false)

        -- Should have unsent user header
        local hasUserHeader = false
        for _, line in ipairs(lines) do
          if line:match("^## User <!%-%-") then
            hasUserHeader = true
          end
        end

        assert.is_true(hasUserHeader, "Should have unsent user header")

        -- Should not have any list items
        local hasListItem = false
        for _, line in ipairs(lines) do
          if line:match("^[%d]+%.") or line:match("^%-") then
            hasListItem = true
          end
        end

        assert.is_false(hasListItem, "Should not have any list items")
      end)
    end)
  end)
end)
