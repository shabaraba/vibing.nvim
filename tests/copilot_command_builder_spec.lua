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
  before_each(function()
    Builder._set_executable_path("/usr/local/bin/copilot")
  end)

  after_each(function()
    Builder._set_executable_path(nil)
  end)

  describe("to_deny_pattern", function()
    it("maps Bash to shell()", function()
      assert.are.equal("shell()", Builder.to_deny_pattern("Bash"))
    end)

    it("maps Bash(npm:*) to shell(npm:*)", function()
      assert.are.equal("shell(npm:*)", Builder.to_deny_pattern("Bash(npm:*)"))
    end)

    it("maps Write and Edit to write()", function()
      assert.are.equal("write()", Builder.to_deny_pattern("Write"))
      assert.are.equal("write()", Builder.to_deny_pattern("Edit"))
    end)

    it("maps WebFetch and WebSearch to url()", function()
      assert.are.equal("url()", Builder.to_deny_pattern("WebFetch"))
      assert.are.equal("url()", Builder.to_deny_pattern("WebSearch"))
    end)

    it("returns nil for unmapped tools", function()
      assert.is_nil(Builder.to_deny_pattern("Read"))
      assert.is_nil(Builder.to_deny_pattern("Glob"))
    end)
  end)

  describe("build_deny_patterns", function()
    it("deduplicates write() from Write and Edit", function()
      local patterns = Builder.build_deny_patterns({ "Write", "Edit", "Bash" })
      assert.are.same({ "write()", "shell()" }, patterns)
    end)

    it("returns an empty list for nil", function()
      assert.are.same({}, Builder.build_deny_patterns(nil))
    end)
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
      assert.is_true(contains(cmd, "shell()"))
      assert.is_true(contains(cmd, "write()"))
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
end)
