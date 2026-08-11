-- Tests for the bundled destructive-command deny rules

local destructive = require("vibing.core.constants.destructive_commands")
local rule_checker = require("vibing.infrastructure.permissions.rule_checker")

---Run a Bash command through every bundled deny rule.
---@param command string
---@return boolean denied
local function is_denied(command)
  for _, rule in ipairs(destructive.DEFAULT_DENY_RULES) do
    if rule_checker.check_rule(rule, "Bash", { command = command }) == "deny" then
      return true
    end
  end
  return false
end

describe("destructive_commands.DEFAULT_DENY_RULES", function()
  describe("rm", function()
    it("blocks recursive deletion of the root and the home directory", function()
      assert.is_true(is_denied("rm -rf /"))
      assert.is_true(is_denied("rm -rf /*"))
      assert.is_true(is_denied("rm -rf / --no-preserve-root"))
      assert.is_true(is_denied("rm -fr /"))
      assert.is_true(is_denied("rm -rf ~"))
      assert.is_true(is_denied("rm -rf ~/Documents"))
      assert.is_true(is_denied("rm -rf $HOME"))
      assert.is_true(is_denied("rm -rf ${HOME}"))
    end)

    it("blocks the GNU longform flag too", function()
      assert.is_true(is_denied("rm --recursive --force /"))
      assert.is_true(is_denied("rm --recursive ~"))
    end)

    it("blocks it after a shell separator, not just at the start of the line", function()
      assert.is_true(is_denied("cd /tmp && rm -rf /"))
      assert.is_true(is_denied("echo hi; rm -rf ~"))
    end)

    it("leaves ordinary deletions alone", function()
      assert.is_false(is_denied("rm -rf node_modules"))
      assert.is_false(is_denied("rm --recursive ./dist/"))
      assert.is_false(is_denied("rm -rf ./dist"))
      assert.is_false(is_denied("rm file.txt"))
      assert.is_false(is_denied("rm -rf /tmp/vibing-test"))
    end)
  end)

  describe("privilege escalation", function()
    it("blocks sudo and doas in command position", function()
      assert.is_true(is_denied("sudo rm file"))
      assert.is_true(is_denied("  sudo -i"))
      assert.is_true(is_denied("make && sudo make install"))
      assert.is_true(is_denied("doas pkg_add tree"))
    end)

    it("does not trip on the word appearing inside an argument", function()
      assert.is_false(is_denied("grep sudo /etc/group"))
      assert.is_false(is_denied("echo 'no sudo here'"))
      assert.is_false(is_denied("ls sudoers.d"))
    end)
  end)

  describe("raw device writes", function()
    it("blocks dd and mkfs", function()
      assert.is_true(is_denied("dd if=/dev/zero of=/dev/disk2"))
      assert.is_true(is_denied("dd if=image.iso of=/dev/sda bs=4M"))
      assert.is_true(is_denied("mkfs.ext4 /dev/sda1"))
      assert.is_true(is_denied("mkfs -t ext4 /dev/sda1"))
    end)

    it("leaves unrelated commands alone", function()
      assert.is_false(is_denied("ls /dev/null"))
      assert.is_false(is_denied("cat file > /dev/null"))
    end)
  end)

  describe("chmod", function()
    it("blocks recursive 777", function()
      assert.is_true(is_denied("chmod -R 777 ."))
      assert.is_true(is_denied("chmod -R 0777 /var/www"))
      assert.is_true(is_denied("chmod --recursive 777 ."))
    end)

    it("allows narrower modes and non-recursive changes", function()
      assert.is_false(is_denied("chmod 777 one-file"))
      assert.is_false(is_denied("chmod -R 755 ."))
      assert.is_false(is_denied("chmod +x script.sh"))
    end)
  end)

  describe("git push", function()
    it("blocks force-pushing main/master", function()
      assert.is_true(is_denied("git push --force origin main"))
      assert.is_true(is_denied("git push --force origin master"))
      assert.is_true(is_denied("git push -f origin main"))
    end)

    it("allows --force-with-lease, and force-pushing other branches", function()
      assert.is_false(is_denied("git push --force-with-lease origin main"))
      assert.is_false(is_denied("git push --force origin my-feature"))
      assert.is_false(is_denied("git push origin main"))
    end)
  end)
end)

describe("can_use_tool with the bundled deny rules", function()
  local can_use_tool = require("vibing.infrastructure.permissions.can_use_tool")

  ---@param overrides table
  ---@return table
  local function perm_config(overrides)
    return vim.tbl_extend("force", {
      allowed_tools = { "Bash" },
      denied_tools = {},
      asked_tools = {},
      session_allowed_tools = {},
      session_denied_tools = {},
      permission_rules = destructive.DEFAULT_DENY_RULES,
      permission_mode = "default",
      mcp_enabled = false,
    }, overrides or {})
  end

  it("denies a destructive command that the allow list would otherwise permit", function()
    local result = can_use_tool.can_use_tool("Bash", { command = "sudo rm -rf /" }, perm_config({}))
    assert.equals("deny", result.behavior)
  end)

  it("still denies under auto mode, which allows everything else outright", function()
    local result =
      can_use_tool.can_use_tool("Bash", { command = "sudo rm -rf /" }, perm_config({ permission_mode = "auto" }))
    assert.equals("deny", result.behavior)

    local harmless = can_use_tool.can_use_tool("Bash", { command = "ls" }, perm_config({ permission_mode = "auto" }))
    assert.equals("allow", harmless.behavior)
  end)

  it("still denies after the user approved some other Bash command for the session", function()
    -- The approval UI records the bare tool name, so "allow_for_session" on `npm install`
    -- matches every later Bash call. It must not thereby approve a destructive one.
    local config = perm_config({ session_allowed_tools = { "Bash" } })

    local result = can_use_tool.can_use_tool("Bash", { command = "sudo rm -rf /" }, config)
    assert.equals("deny", result.behavior)

    -- The session grant still does its job for everything else.
    local harmless = can_use_tool.can_use_tool("Bash", { command = "npm install" }, config)
    assert.equals("allow", harmless.behavior)
  end)

  it("still lets bypassPermissions through, as the documented escape hatch", function()
    local result = can_use_tool.can_use_tool(
      "Bash",
      { command = "sudo rm -rf /" },
      perm_config({ permission_mode = "bypassPermissions" })
    )
    assert.equals("allow", result.behavior)
  end)

  it("does not deny anything once the rules are removed", function()
    local result =
      can_use_tool.can_use_tool("Bash", { command = "sudo apt install tree" }, perm_config({ permission_rules = {} }))
    assert.equals("allow", result.behavior)
  end)

  it("surfaces the rule's own message so the model knows why", function()
    local result = can_use_tool.can_use_tool("Bash", { command = "sudo apt install tree" }, perm_config({}))
    assert.equals("deny", result.behavior)
    assert.is_truthy(result.message:find("default deny rules", 1, true))
  end)
end)
