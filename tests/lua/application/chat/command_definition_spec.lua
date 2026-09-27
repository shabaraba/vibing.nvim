-- `gd` の `/name` → 定義ファイル解決。
--
-- 守りたいのは2つ。カーソル下のトークンを「コマンド名」と読む条件（パスやURLを巻き込まない、
-- `plugin:skill` のコロンを落とさない）と、解決順（project → user → plugin、同名ならskillが先）。
-- スキルの `name` はディレクトリ名ではなくfrontmatter側が正なので、そこも固定する。

local CommandDefinition = require("vibing.application.chat.command_definition")

describe("command_definition.name_on_line", function()
  -- 行の中の `pattern` の1文字目にカーソルがある状態で読む
  local function at(line, pattern)
    local col = assert(line:find(pattern, 1, true), "pattern not in line")
    return CommandDefinition.name_on_line(line, col)
  end

  it("reads a bare command name", function()
    assert.equals("graphify", at("/graphify", "/graphify"))
    assert.equals("code-review", at("run /code-review please", "/code-review"))
  end)

  it("reads the name wherever in it the cursor sits", function()
    local line = "  /simplify now"
    assert.equals("simplify", CommandDefinition.name_on_line(line, 3))
    assert.equals("simplify", CommandDefinition.name_on_line(line, 7))
    assert.equals("simplify", CommandDefinition.name_on_line(line, 11))
  end)

  it("keeps a namespaced name whole", function()
    -- `<cfile>` はunixの既定 `isfname` にコロンが無いので `/vibing-nvim` で切れる。
    -- ここが切れると plugin 側の解決が一切当たらない
    assert.equals(
      "vibing-nvim:vibing-code-tour",
      at("/vibing-nvim:vibing-code-tour", "/vibing-nvim")
    )
  end)

  it("unwraps markdown around the name", function()
    assert.equals("dataviz", at("use `/dataviz` for charts", "/dataviz"))
    assert.equals("run", at("**/run**", "/run"))
  end)

  it("drops trailing prose punctuation", function()
    assert.equals("simplify", at("then /simplify.", "/simplify"))
    assert.equals("loop", at("/loop:", "/loop"))
  end)

  it("rejects a file path", function()
    assert.is_nil(at("/Users/shaba/x.lua", "/Users"))
    assert.is_nil(at("/Users/shaba/x.lua", "/shaba"))
    assert.is_nil(at("lua/vibing/config.lua", "/vibing"))
  end)

  it("rejects a URL", function()
    assert.is_nil(at("see https://example.com/page for more", "/page"))
    assert.is_nil(at("https://example.com/a", "//example"))
  end)

  it("returns nil when the cursor is not inside a name", function()
    local line = "text /graphify text"
    assert.is_nil(CommandDefinition.name_on_line(line, 1))
    assert.is_nil(CommandDefinition.name_on_line(line, #line))
    assert.is_nil(CommandDefinition.name_on_line("no slash here", 3))
    assert.is_nil(CommandDefinition.name_on_line("", 1))
  end)

  it("returns nil for a slash followed by punctuation only", function()
    assert.is_nil(at("a /-- b", "/--"))
  end)
end)

describe("command_definition.resolve", function()
  local Fs = require("vibing.core.utils.fs")

  local root
  local home
  local base
  local saved_home

  local function write(path, lines)
    Fs.ensure_dir(vim.fn.fnamemodify(path, ":h"))
    vim.fn.writefile(lines, path)
  end

  before_each(function()
    base = vim.fn.tempname()
    root = base .. "/project"
    home = base .. "/home"
    Fs.ensure_dir(root)
    Fs.ensure_dir(home)
    -- `~` の展開先を差し替えて、実際のユーザーの `.claude/` を読まないようにする
    saved_home = vim.env.HOME
    vim.env.HOME = home
  end)

  after_each(function()
    vim.env.HOME = saved_home
    vim.fn.delete(base, "rf")
  end)

  it("finds a project skill", function()
    local path = root .. "/.claude/skills/temp-skill/SKILL.md"
    write(path, { "---", "description: x", "---" })

    assert.equals(path, CommandDefinition.resolve("temp-skill", root))
  end)

  describe("a command the chat would expand itself", function()
    local Commands = require("vibing.application.chat.commands")

    after_each(function()
      Commands.custom_commands["reg-cmd"] = nil
    end)

    -- `/reg-cmd` を展開するのは `commands.lua` のレジストリなので、`gd` はそこが持っている
    -- ファイルを開かないといけない。自前でパスを探すと優先順位が二重になり、実行される
    -- ファイルと開かれるファイルが食い違う
    it("comes from the registry, not from a second path search", function()
      local registered = root .. "/elsewhere/reg-cmd.md"
      write(registered, { "# Registered" })
      Commands.register_custom({
        name = "reg-cmd",
        description = "x",
        source = "project",
        file_path = registered,
        content = "body",
      })

      assert.equals(registered, CommandDefinition.resolve("reg-cmd", root))
    end)

    it("outranks a same-named skill, which vibing.nvim never reaches", function()
      write(root .. "/.claude/skills/reg-cmd/SKILL.md", { "---", "description: x", "---" })
      local registered = root .. "/.claude/commands/reg-cmd.md"
      write(registered, { "# Registered" })
      Commands.register_custom({
        name = "reg-cmd",
        description = "x",
        source = "project",
        file_path = registered,
        content = "body",
      })

      assert.equals(registered, CommandDefinition.resolve("reg-cmd", root))
    end)
  end)

  it("finds a project command", function()
    local path = root .. "/.claude/commands/temp-cmd.md"
    write(path, { "# Temp" })

    assert.equals(path, CommandDefinition.resolve("temp-cmd", root))
  end)

  it("finds a user skill and command", function()
    write(home .. "/.claude/skills/user-skill/SKILL.md", { "---", "description: x", "---" })
    write(home .. "/.claude/commands/user-cmd.md", { "# User" })

    -- `~` 経由で解決するので、期待値も同じ展開を通す（macOSでは /var が /private/var になる）
    assert.equals(
      vim.fn.expand("~/.claude/skills/user-skill/SKILL.md"),
      CommandDefinition.resolve("user-skill", root)
    )
    assert.equals(
      vim.fn.expand("~/.claude/commands/user-cmd.md"),
      CommandDefinition.resolve("user-cmd", root)
    )
  end)

  it("prefers the project over the user location", function()
    local project = root .. "/.claude/skills/both/SKILL.md"
    write(project, { "---", "description: project", "---" })
    write(home .. "/.claude/skills/both/SKILL.md", { "---", "description: user", "---" })

    assert.equals(project, CommandDefinition.resolve("both", root))
  end)

  it("prefers a skill over a command of the same name", function()
    local skill = root .. "/.claude/skills/twin/SKILL.md"
    write(skill, { "---", "description: x", "---" })
    write(root .. "/.claude/commands/twin.md", { "# Twin" })

    assert.equals(skill, CommandDefinition.resolve("twin", root))
  end)

  it("resolves a command in a subdirectory from its namespaced name", function()
    local path = root .. "/.claude/commands/ns/inner.md"
    write(path, { "# Inner" })

    assert.equals(path, CommandDefinition.resolve("ns:inner", root))
  end)

  it("answers for the cwd it is given, not for Neovim's", function()
    write(root .. "/.claude/skills/only-here/SKILL.md", { "---", "description: x", "---" })

    assert.is_nil(CommandDefinition.resolve("only-here", home))
  end)

  it("returns nil for a name with no file anywhere", function()
    assert.is_nil(CommandDefinition.resolve("no-such-command-xyz", root))
    assert.is_nil(CommandDefinition.resolve("plug-xyz:skill-xyz", root))
    assert.is_nil(CommandDefinition.resolve("", root))
  end)

  describe("plugins handed over with --plugin-dir", function()
    local plugin_dir
    local saved_plugin_dirs

    before_each(function()
      plugin_dir = root .. "/plug"
      write(plugin_dir .. "/.claude-plugin/plugin.json", { '{ "name": "tmp-plug" }' })
      -- スキルの表示名はディレクトリ名ではなくfrontmatterの `name`。CLIが名乗る名前＝
      -- ユーザーが打つ名前なので、解決もそちらに一致しないといけない
      write(plugin_dir .. "/skills/dir-name/SKILL.md", { "---", "name: declared-name", "---" })
      write(plugin_dir .. "/commands/plug-cmd.md", { "# Plug" })

      saved_plugin_dirs = package.loaded["vibing.infrastructure.plugins.plugin_dirs"]
      package.loaded["vibing.infrastructure.plugins.plugin_dirs"] = {
        resolve_entries = function()
          return { { name = "tmp-plug", path = plugin_dir } }
        end,
      }
    end)

    after_each(function()
      package.loaded["vibing.infrastructure.plugins.plugin_dirs"] = saved_plugin_dirs
    end)

    it("finds a skill by the name its frontmatter declares", function()
      -- ディレクトリ名の決め打ちでは当たらないので、SKILL.mdを読む側の経路が要る
      assert.equals(
        plugin_dir .. "/skills/dir-name/SKILL.md",
        CommandDefinition.resolve("declared-name", root)
      )
      -- ディレクトリ名でも同じファイルに着く。CLIが名乗るのは `declared-name` だけなので
      -- `/dir-name` はコマンドとしては存在しないが、決め打ちの1statを先に試す（実測で
      -- 同梱スキルは12/12が一致し、外すと毎打鍵0.4msのSKILL.md全読みになる）以上、
      -- 実在するファイルに着くこの結果は許容する
      assert.equals(
        plugin_dir .. "/skills/dir-name/SKILL.md",
        CommandDefinition.resolve("dir-name", root)
      )
    end)

    it("finds a skill by its namespaced name", function()
      assert.equals(
        plugin_dir .. "/skills/dir-name/SKILL.md",
        CommandDefinition.resolve("tmp-plug:declared-name", root)
      )
    end)

    it("ignores a plugin whose name is not the one asked about", function()
      assert.is_nil(CommandDefinition.resolve("other-plug:declared-name", root))
    end)

    it("finds a plugin command", function()
      assert.equals(
        plugin_dir .. "/commands/plug-cmd.md",
        CommandDefinition.resolve("plug-cmd", root)
      )
    end)
  end)
end)

describe("command_definition.is_known", function()
  local saved = {}

  local function stub(name, module)
    saved[name] = saved[name] or { value = package.loaded[name], had = package.loaded[name] ~= nil }
    package.loaded[name] = module
  end

  after_each(function()
    for name, entry in pairs(saved) do
      package.loaded[name] = entry.had and entry.value or nil
    end
    saved = {}
  end)

  it("knows a command vibing.nvim registers itself", function()
    stub("vibing.application.chat.commands", {
      list_all = function()
        return { model = { name = "model" } }
      end,
    })

    assert.is_true(CommandDefinition.is_known("model"))
    assert.is_false(CommandDefinition.is_known("nope-xyz"))
  end)

  it("knows a skill the CLI reported, once its list is cached", function()
    stub("vibing.application.chat.commands", {
      list_all = function()
        return {}
      end,
    })
    stub("vibing.infrastructure.completion.providers.skills", {
      peek_cli_commands = function()
        return { { word = "code-review" } }
      end,
    })

    assert.is_true(CommandDefinition.is_known("code-review"))
    assert.is_false(CommandDefinition.is_known("nope-xyz"))
  end)

  it("never asks for the CLI's list in a way that could fetch it", function()
    -- `get_all()` はキャッシュが陳腐化していれば `claude` を起こす（cwdが動いた直後がそれ）。
    -- キーを1回押しただけで起こしてはいけないので、経路そのものを使わない
    local fetched = false
    stub("vibing.application.chat.commands", {
      list_all = function()
        return {}
      end,
    })
    stub("vibing.infrastructure.completion.providers.skills", {
      peek_cli_commands = function()
        return {}
      end,
      get_all = function()
        fetched = true
        return {}
      end,
      is_preloading = function()
        return false
      end,
    })

    assert.is_false(CommandDefinition.is_known("code-review"))
    assert.is_false(fetched)
  end)
end)
