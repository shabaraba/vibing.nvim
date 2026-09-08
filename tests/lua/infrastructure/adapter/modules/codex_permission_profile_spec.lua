local profile = require("vibing.infrastructure.adapter.modules.codex_permission_profile")

describe("codex_permission_profile", function()
  local root
  local config
  local original_getcwd
  local original_system

  local function write_at(base, content)
    vim.fn.mkdir(base .. "/.vibing", "p")
    vim.fn.writefile(
      vim.split(content, "\n", { plain = true }),
      base .. "/.vibing/codex-permissions.toml"
    )
  end

  local function override_map(args)
    local result = {}
    for index, item in ipairs(args) do
      if item == "-c" then
        local assignment = args[index + 1]
        local equals = assignment:find("=", 1, true)
        result[assignment:sub(1, equals - 1)] = assignment:sub(equals + 1)
      end
    end
    return result
  end

  local function expect_error(fragment, callback)
    local ok, problem = pcall(callback)
    assert.is_false(ok)
    assert.is_not_nil(tostring(problem):find(fragment, 1, true), tostring(problem))
  end

  before_each(function()
    root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")
    config = { permissions = { codex_profile_file = ".vibing/codex-permissions.toml" } }
    original_getcwd = vim.fn.getcwd
    original_system = vim.system
    vim.fn.getcwd = function()
      return root
    end
    profile.clear_cache()
  end)

  after_each(function()
    vim.fn.getcwd = original_getcwd
    vim.system = original_system
    profile.clear_cache()
    vim.fn.delete(root, "rf")
  end)

  it("turns standard Codex profile tables into stable inline overrides", function()
    write_at(root, [[
# This is ordinary Codex permission-profile TOML.
default_permissions = "project-edit"

[features]
network_proxy = true

[permissions.project-edit]
extends = ":workspace"
description = "Git metadata access # stays inside the string"

[permissions.project-edit.filesystem.":workspace_roots"]
".git" = "write"
"generated" = "deny"

[permissions.project-edit.network]
enabled = true

[permissions.project-edit.network.domains]
"github.com" = "allow"
"*.github.com" = "allow" # an actual comment
]])

    local overrides = override_map(profile.args(root, config))
    assert.equals('"project-edit"', overrides.default_permissions)
    assert.equals("true", overrides["features.network_proxy"])
    assert.equals(
      '{ project-edit = { description = "Git metadata access # stays inside the string", extends = ":workspace", filesystem = { ":workspace_roots" = { ".git" = "write", generated = "deny" } }, network = { domains = { "*.github.com" = "allow", "github.com" = "allow" }, enabled = true } } }',
      overrides.permissions
    )
  end)

  it("renders the same bytes regardless of table and field order", function()
    write_at(root, [[
default_permissions = "project-edit"
[permissions.project-edit.network]
enabled = true
[permissions.project-edit]
extends = ":workspace"
]])
    local first = profile.args(root, config)

    write_at(root, [[
default_permissions = "project-edit"
[permissions.project-edit]
extends = ":workspace"
[permissions.project-edit.network]
enabled = true
]])
    assert.same(first, profile.args(root, config))
  end)

  it("falls back from a worktree to the Neovim project root", function()
    local worktree = root .. "/.vibing/worktrees/feature-x"
    vim.fn.mkdir(worktree, "p")
    write_at(root, [[
default_permissions = "root-profile"
[permissions.root-profile]
extends = ":workspace"
]])
    vim.system = function(command, opts)
      assert.same({ "git", "rev-parse", "--path-format=absolute", "--git-common-dir" }, command)
      assert.is_true(opts.cwd == root or opts.cwd == worktree)
      return {
        wait = function()
          return { code = 0, stdout = root .. "/.git\n" }
        end,
      }
    end

    local overrides = override_map(profile.args(worktree, config))
    assert.equals('"root-profile"', overrides.default_permissions)
  end)

  it("does not inherit the Neovim root profile in an unrelated repository", function()
    local unrelated = vim.fn.tempname()
    vim.fn.mkdir(unrelated, "p")
    write_at(root, 'default_permissions = ":workspace"')
    vim.system = function(_, opts)
      return {
        wait = function()
          return { code = 0, stdout = opts.cwd .. "/.git\n" }
        end,
      }
    end

    assert.same({}, profile.args(unrelated, config))
    vim.fn.delete(unrelated, "rf")
  end)

  it("prefers a worktree-local profile", function()
    local worktree = root .. "/.vibing/worktrees/feature-x"
    vim.fn.mkdir(worktree, "p")
    write_at(root, [[
default_permissions = "root-profile"
[permissions.root-profile]
extends = ":workspace"
]])
    write_at(worktree, [[
default_permissions = "worktree-profile"
[permissions.worktree-profile]
extends = ":workspace"
]])

    local overrides = override_map(profile.args(worktree, config))
    assert.equals('"worktree-profile"', overrides.default_permissions)
  end)

  it("maps .git write access to a linked worktree's common git directory", function()
    local worktree = root .. "/.vibing/worktrees/feature-x"
    vim.fn.mkdir(worktree, "p")
    write_at(root, [[
default_permissions = "project-edit"
[permissions.git-base]
extends = ":workspace"
[permissions.git-base.filesystem.":workspace_roots"]
".git" = "write"
[permissions.project-edit]
extends = "git-base"
    ]])
    vim.system = function(command, opts)
      assert.same({ "git", "rev-parse", "--path-format=absolute", "--git-common-dir" }, command)
      assert.is_true(opts.cwd == root or opts.cwd == worktree)
      return {
        wait = function()
          return { code = 0, stdout = root .. "/.git\n" }
        end,
      }
    end

    local overrides = override_map(profile.args(worktree, config))
    assert.is_not_nil(
      overrides.permissions:find('"' .. root .. '/.git" = "write"', 1, true),
      overrides.permissions
    )
  end)

  it("does not reuse a main-checkout cache entry for a linked worktree", function()
    local worktree = root .. "/.vibing/worktrees/feature-x"
    vim.fn.mkdir(worktree, "p")
    write_at(root, [[
default_permissions = "project-edit"
[permissions.project-edit]
extends = ":workspace"
[permissions.project-edit.filesystem.":workspace_roots"]
".git" = "write"
]])
    vim.system = function(_, _)
      return {
        wait = function()
          return { code = 0, stdout = root .. "/.git\n" }
        end,
      }
    end

    local main_permissions = override_map(profile.args(root, config)).permissions
    assert.is_nil(main_permissions:find('"' .. root .. '/.git"', 1, true))

    local worktree_permissions = override_map(profile.args(worktree, config)).permissions
    assert.is_not_nil(worktree_permissions:find('"' .. root .. '/.git" = "write"', 1, true))
  end)

  it("does nothing when the file is absent, empty, or disabled", function()
    assert.same({}, profile.args(root, config))
    write_at(root, "# no profile yet")
    assert.same({}, profile.args(root, config))
    config.permissions.codex_profile_file = false
    assert.same({}, profile.args(root, config))
  end)

  it("accepts a safe built-in profile without a custom definition", function()
    write_at(root, 'default_permissions = ":read-only"')
    assert.same({ "-c", 'default_permissions=":read-only"' }, profile.args(root, config))
  end)

  it("fails closed when the selected custom profile is absent", function()
    write_at(root, 'default_permissions = "missing"')
    expect_error('selected profile "missing" is not defined', function()
      profile.args(root, config)
    end)
  end)

  it("fails closed when the selected custom profile is not a table", function()
    write_at(root, [[
default_permissions = "broken"
permissions.broken = true
]])
    expect_error('selected profile "broken" must be a table', function()
      profile.args(root, config)
    end)
  end)

  it("refuses project-local danger-full-access", function()
    write_at(root, 'default_permissions = ":danger-full-access"')
    expect_error(":danger-full-access is not allowed", function()
      profile.args(root, config)
    end)
  end)

  it("rejects unrelated Codex configuration", function()
    write_at(root, [[
default_permissions = ":workspace"
model = "gpt-5.6"
]])
    expect_error('unsupported top-level key "model"', function()
      profile.args(root, config)
    end)

    write_at(root, [[
default_permissions = ":workspace"
[features]
multi_agent = true
]])
    expect_error("only features.network_proxy is allowed", function()
      profile.args(root, config)
    end)
  end)

  it("reports malformed input with its line number", function()
    write_at(root, [[
default_permissions = "project-edit"
[permissions.project-edit]
extends ":workspace"
]])
    expect_error("codex-permissions.toml:3: expected a single-line key = value assignment", function()
      profile.args(root, config)
    end)
  end)
end)
