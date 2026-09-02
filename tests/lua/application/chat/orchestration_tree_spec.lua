-- frontmatter が既に持っている木を読み出せるか。ここが読めないと、可視化もツリー cancel も
-- 「オーケストレーターが直接配った1階層」しか見えない（#645）。

local Git = require("vibing.core.utils.git")
local ChatFiles = require("tests.helpers.chat_files")

describe("OrchestrationTree", function()
  ---gitルートのキャッシュはモジュールレベルなのでspec間で持ち越す。毎回requireし直して捨てる
  local Tree
  local original_get_root
  local dir
  local buffers = {}

  before_each(function()
    original_get_root = Git.get_root
    dir = vim.fn.resolve(vim.fn.tempname())
    vim.fn.mkdir(dir, "p")
    buffers = {}

    Git.get_root = function()
      return dir
    end

    package.loaded["vibing.application.chat.chat_locator"] = nil
    package.loaded["vibing.application.chat.orchestration_tree"] = nil
    Tree = require("vibing.application.chat.orchestration_tree")
  end)

  after_each(function()
    Git.get_root = original_get_root
    for _, bufnr in ipairs(buffers) do
      if vim.api.nvim_buf_is_valid(bufnr) then
        vim.api.nvim_buf_delete(bufnr, { force = true })
      end
    end
    vim.fn.delete(dir, "rf")
  end)

  ---@param name string
  ---@return number bufnr
  local function open_buffer(name)
    local bufnr = vim.fn.bufadd(dir .. "/" .. name)
    vim.fn.bufload(bufnr)
    table.insert(buffers, bufnr)
    return bufnr
  end

  ---@param node table
  ---@return string[]
  local function paths_of(node)
    local paths = {}
    for _, entry in ipairs(Tree.flatten(node)) do
      table.insert(paths, entry.path)
    end
    return paths
  end

  it("reads a whole tree out of chat files that are not open", function()
    -- 木のノードの大半は `back` で作られた窓なしのワーカーで、開いていないことのほうが普通
    ChatFiles.write(dir, "root.md", { orchestrated = { "b.md", "c.md" } })
    ChatFiles.write(dir, "b.md", { orchestrated_by = { "root.md" } })
    ChatFiles.write(dir, "c.md", { orchestrated_by = { "root.md" }, orchestrated = { "d.md" } })
    ChatFiles.write(dir, "d.md", { orchestrated_by = { "c.md" } })

    assert.same({ "root.md", "b.md", "c.md", "d.md" }, paths_of(Tree.build("root.md")))
  end)

  it("prefers the buffer over the file, so a dispatch not yet saved still shows", function()
    -- オーケストレーターは配布のたびに `orchestrated` を書き足す。保存が追いつく前に木を見て
    -- 新しい子が消えるなら、いちばん見たい瞬間に見えないことになる
    ChatFiles.write(dir, "root.md", {})
    ChatFiles.write(dir, "b.md", {})

    local bufnr = open_buffer("root.md")
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    table.insert(lines, 2, "orchestrated:")
    table.insert(lines, 3, "  - b.md")
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)

    assert.same({ "root.md", "b.md" }, paths_of(Tree.build("root.md")))
  end)

  it("attaches the buffer number of a chat that is open", function()
    ChatFiles.write(dir, "root.md", { orchestrated = { "b.md" } })
    ChatFiles.write(dir, "b.md", {})
    local bufnr = open_buffer("b.md")

    local root = Tree.build("root.md")
    assert.is_nil(root.bufnr)
    assert.equals(bufnr, root.children[1].bufnr)
  end)

  it("stops at a chat it has already drawn instead of looping forever", function()
    -- frontmatter は手で書けるので循環しうる。落とさずに描いて、辿り直しだけをやめる
    ChatFiles.write(dir, "a.md", { orchestrated = { "b.md" } })
    ChatFiles.write(dir, "b.md", { orchestrated = { "a.md" } })

    local nodes = Tree.flatten(Tree.build("a.md"))

    assert.same({ "a.md", "b.md", "a.md" }, { nodes[1].path, nodes[2].path, nodes[3].path })
    assert.equals(3, #nodes)
    assert.is_true(nodes[3].repeated)
  end)

  it("returns nothing for a path it cannot resolve", function()
    assert.is_nil(Tree.build(""))
  end)

  it("returns nothing for a path with no chat behind it", function()
    -- 打ち間違えたパスも表示パスとしては解決できるので、確かめないと「誰も動かしていない
    -- チャット」の体裁で1ノードの木が返る
    assert.is_nil(Tree.build("typo.md"))
  end)

  it("still draws a child whose file has gone, since the frontmatter still names it", function()
    ChatFiles.write(dir, "root.md", { orchestrated = { "gone.md" } })

    assert.same({ "root.md", "gone.md" }, paths_of(Tree.build("root.md")))
  end)

  it("reads a tree from a chat file with no orchestration at all", function()
    ChatFiles.write(dir, "solo.md", {})

    local root = Tree.build("solo.md")
    assert.same({}, root.children)
  end)

  describe("root_of", function()
    it("walks orchestrated_by up to the top", function()
      ChatFiles.write(dir, "root.md", { orchestrated = { "mid.md" } })
      ChatFiles.write(dir, "mid.md", { orchestrated_by = { "root.md" }, orchestrated = { "leaf.md" } })
      ChatFiles.write(dir, "leaf.md", { orchestrated_by = { "mid.md" } })

      assert.equals("root.md", Tree.root_of("leaf.md"))
    end)

    it("returns the path itself when nothing orchestrates it", function()
      ChatFiles.write(dir, "root.md", {})

      assert.equals("root.md", Tree.root_of("root.md"))
    end)

    it("gives up on a cycle rather than climbing forever", function()
      ChatFiles.write(dir, "a.md", { orchestrated_by = { "b.md" } })
      ChatFiles.write(dir, "b.md", { orchestrated_by = { "a.md" } })

      assert.equals("a.md", Tree.root_of("a.md"))
    end)
  end)
end)
