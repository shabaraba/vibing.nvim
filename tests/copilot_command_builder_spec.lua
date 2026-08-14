local Builder = require("vibing.infrastructure.adapter.modules.copilot_command_builder")

---コマンド配列に指定の値が含まれるか
---@param cmd string[]
---@param value string
---@return boolean
local function contains(cmd, value)
  for _, v in ipairs(cmd) do
    if v == value then
      return true
    end
  end
  return false
end

---コマンド配列内で flag の直後に来る値を返す
---@param cmd string[]
---@param flag string
---@return string|nil
local function value_after(cmd, flag)
  for i, v in ipairs(cmd) do
    if v == flag then
      return cmd[i + 1]
    end
  end
  return nil
end

describe("copilot_command_builder", function()
  local original_exepath

  before_each(function()
    original_exepath = vim.fn.exepath
    vim.fn.exepath = function()
      return "/usr/local/bin/copilot"
    end
    -- The builder's resolved path is cached at module scope, so without this only the first
    -- test's stub would take effect and every later one would read test #1's value. It passes
    -- today only because every test here stubs the same constant path.
    require("tests.helpers.adapter_stream").reset_path_caches()
  end)

  after_each(function()
    vim.fn.exepath = original_exepath
  end)

  describe("build", function()
    it("emits the base flags with the prompt last", function()
      local cmd = Builder.build("hello", {}, nil, {})
      assert.are.equal("/usr/local/bin/copilot", cmd[1])
      assert.is_true(contains(cmd, "--output-format"))
      assert.are.equal("json", value_after(cmd, "--output-format"))
      assert.are.equal("on", value_after(cmd, "--stream"))
      assert.is_true(contains(cmd, "--no-color"))
      assert.are.equal("-p", cmd[#cmd - 1])
      assert.are.equal("hello", cmd[#cmd])
    end)

    it("adds --resume when a session id is given", function()
      local cmd = Builder.build("hi", {}, "sess-123", {})
      assert.is_true(contains(cmd, "--resume=sess-123"))
    end)

    it("omits --resume for a new session", function()
      local cmd = Builder.build("hi", {}, nil, {})
      assert.is_nil(value_after(cmd, "--resume"))
      for _, v in ipairs(cmd) do
        assert.is_nil(v:match("^%-%-resume="))
      end
    end)

    it("passes through copilot model ids", function()
      local cmd = Builder.build("hi", { model = "gpt-5.5" }, nil, {})
      assert.are.equal("gpt-5.5", value_after(cmd, "--model"))
    end)

    it("drops claude short model names", function()
      local cmd = Builder.build("hi", { model = "sonnet" }, nil, {})
      assert.is_nil(value_after(cmd, "--model"))
    end)

    it("falls back to config.agent.default_model", function()
      local cmd = Builder.build("hi", {}, nil, { agent = { default_model = "claude-opus-5" } })
      assert.are.equal("claude-opus-5", value_after(cmd, "--model"))
    end)

    it("maps bypassPermissions to --allow-all", function()
      local cmd = Builder.build("hi", { permission_mode = "bypassPermissions" }, nil, {})
      assert.is_true(contains(cmd, "--allow-all"))
      assert.is_false(contains(cmd, "--allow-all-tools"))
    end)

    it("maps plan to --plan plus --allow-all-tools", function()
      local cmd = Builder.build("hi", { permission_mode = "plan" }, nil, {})
      assert.is_true(contains(cmd, "--plan"))
      assert.is_true(contains(cmd, "--allow-all-tools"))
    end)

    it("expands the deny list into --deny-tool flags", function()
      local cmd = Builder.build("hi", {
        permission_mode = "acceptEdits",
        permissions_deny = { "Bash", "Write" },
      }, nil, {})
      assert.is_true(contains(cmd, "--allow-all-tools"))
      assert.is_true(contains(cmd, "--deny-tool"))
      assert.is_true(contains(cmd, "shell"))
      assert.is_true(contains(cmd, "write"))
    end)

    it("ignores the deny list under bypassPermissions", function()
      local cmd = Builder.build("hi", {
        permission_mode = "bypassPermissions",
        permissions_deny = { "Bash" },
      }, nil, {})
      assert.is_false(contains(cmd, "--deny-tool"))
    end)

    it("prefixes context files for a new session", function()
      local cmd = Builder.build("hi", { context = { "@file:lua/init.lua" } }, nil, {})
      assert.are.equal("Context file: lua/init.lua\n\nhi", cmd[#cmd])
    end)

    it("omits the context prefix when resuming", function()
      local cmd = Builder.build("hi", { context = { "@file:lua/init.lua" } }, "sess-1", {})
      assert.are.equal("hi", cmd[#cmd])
    end)

    it("prefixes a language instruction", function()
      local cmd = Builder.build("hi", { language = "ja" }, nil, {})
      assert.are.equal("Always respond in Japanese (ja).\n\nhi", cmd[#cmd])
    end)

    it("skips the language instruction for en", function()
      local cmd = Builder.build("hi", { language = "en" }, nil, {})
      assert.are.equal("hi", cmd[#cmd])
    end)
  end)

  describe("lightweight mode", function()
    --- The `--available-tools=<name>` argument, which copilot takes as one argv token.
    local function available_tools(cmd)
      for _, arg in ipairs(cmd) do
        local value = arg:match("^%-%-available%-tools=(.*)$")
        if value then
          return value
        end
      end
      return nil
    end

    it("leaves the model no tools, by naming one copilot does not have", function()
      -- Unlike codex, copilot can genuinely remove the tools, so this pins an empty toolset
      -- rather than a sandbox around a toolset that has to stay. `--available-tools=` would not
      -- do it: an empty list is ignored outright, leaving every tool in place. The sentinel is
      -- what makes the filter match nothing instead.
      local cmd = Builder.build("hi", { lightweight = true }, nil, {})
      local value = available_tools(cmd)
      assert.is_not_nil(value)
      assert.are_not.equal("", value)
      for _, real_tool in ipairs({ "bash", "view", "create", "edit", "web_search", "task" }) do
        assert.are_not.equal(real_tool, value)
      end
    end)

    it("reads no AGENTS.md, the way the claude path reads no CLAUDE.md", function()
      local cmd = Builder.build("hi", { lightweight = true }, nil, {})
      assert.is_true(contains(cmd, "--no-custom-instructions"))
    end)

    it("keeps --allow-all-tools, which copilot requires in non-interactive mode", function()
      local cmd = Builder.build("hi", { lightweight = true }, nil, {})
      assert.is_true(contains(cmd, "--allow-all-tools"))
    end)

    it("does not inherit the chat's plan mode", function()
      local cmd = Builder.build("hi", { lightweight = true, permission_mode = "plan" }, nil, {})
      assert.is_false(contains(cmd, "--plan"))
    end)

    it("stays tool-free even when the chat is in bypassPermissions", function()
      -- The user put the chat in that mode; a title generated behind their back is not the call
      -- they made, so the utility call does not inherit it.
      local cmd =
        Builder.build("hi", { lightweight = true, permission_mode = "bypassPermissions" }, nil, {})
      assert.is_false(contains(cmd, "--allow-all"))
      assert.is_not_nil(available_tools(cmd))
    end)

    it("carries none of the chat's deny patterns", function()
      -- With no tools to gate, a --deny-tool would be describing a toolset that isn't there.
      local cmd = Builder.build("hi", { lightweight = true, permissions_deny = { "Bash" } }, nil, {})
      assert.is_false(contains(cmd, "--deny-tool"))
    end)

    it("still restricts a resumed session, which /summarize always is", function()
      local cmd = Builder.build("hi", { lightweight = true }, "sess-1", {})
      assert.is_not_nil(available_tools(cmd))
      assert.is_true(contains(cmd, "--no-custom-instructions"))
    end)

    it("leaves an ordinary call's tools untouched", function()
      local cmd = Builder.build("hi", {}, nil, {})
      assert.is_nil(available_tools(cmd))
      assert.is_false(contains(cmd, "--no-custom-instructions"))
    end)

    it("uses utility_model rather than default_model", function()
      local config = { agent = { default_model = "gpt-5", utility_model = "gpt-5-mini" } }
      local cmd = Builder.build("hi", { lightweight = true }, nil, config)
      assert.are.equal("gpt-5-mini", value_after(cmd, "--model"))
    end)
  end)
end)
