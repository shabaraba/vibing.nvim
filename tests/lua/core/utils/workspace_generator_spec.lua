-- tests/lua/core/utils/workspace_generator_spec.lua
local WorkspaceGenerator = require("vibing.core.utils.workspace_generator")

describe("vibing.core.utils.workspace_generator", function()
  describe("sanitize_branch", function()
    it("lowercases and hyphenates", function()
      assert.equals("fix-auth-session-bug", WorkspaceGenerator.sanitize_branch("Fix Auth Session Bug"))
    end)

    it("strips non-alphanumeric characters", function()
      assert.equals("fix-auth-bug", WorkspaceGenerator.sanitize_branch("Fix: Auth Bug!!"))
    end)

    it("collapses repeated separators and trims edges", function()
      assert.equals("fix-bug", WorkspaceGenerator.sanitize_branch("  --Fix   Bug--  "))
    end)

    it("truncates to 50 characters", function()
      local long = string.rep("a", 80)
      local result = WorkspaceGenerator.sanitize_branch(long)
      assert.equals(50, #result)
    end)
  end)

  describe("generate", function()
    before_each(function()
      package.loaded["vibing"] = {
        get_adapter = function()
          return {
            stream = function(_, prompt, opts, on_chunk, on_done)
              on_chunk("DESCRIPTION: 認証セッションのバグ修正\nBRANCH: Fix Auth Session Bug\n")
              on_done({})
            end,
          }
        end,
        get_config = function()
          return { language = "ja", permissions = { mode = "acceptEdits", allow = {}, deny = {} } }
        end,
      }
    end)

    after_each(function()
      package.loaded["vibing"] = nil
    end)

    it("parses description and sanitized branch from the AI response", function()
      local result, err
      WorkspaceGenerator.generate("I need to fix a bug in the auth session handling", function(r, e)
        result, err = r, e
      end)

      assert.is_nil(err)
      assert.equals("認証セッションのバグ修正", result.description)
      assert.equals("fix-auth-session-bug", result.branch)
    end)

    it("returns an error for empty input", function()
      local result, err
      WorkspaceGenerator.generate("", function(r, e)
        result, err = r, e
      end)

      assert.is_nil(result)
      assert.is_not_nil(err)
    end)

    it("returns an error when sanitized branch is empty", function()
      local original_package = package.loaded["vibing"]
      package.loaded["vibing"] = {
        get_adapter = function()
          return {
            stream = function(_, prompt, opts, on_chunk, on_done)
              on_chunk("DESCRIPTION: タスク\nBRANCH: 日本語のみ\n")
              on_done({})
            end,
          }
        end,
        get_config = function()
          return { language = "ja", permissions = { mode = "acceptEdits", allow = {}, deny = {} } }
        end,
      }

      local result, err
      WorkspaceGenerator.generate("Some task description", function(r, e)
        result, err = r, e
      end)

      assert.is_nil(result)
      assert.is_not_nil(err)

      package.loaded["vibing"] = original_package
    end)
  end)
end)
