-- 木を罫線付きの行にする。状態を貼るのはここで、木を組む側ではない（#645）。

local ChatStatus = require("vibing.presentation.chat.modules.chat_status")
local Renderer = require("vibing.presentation.chat.modules.orchestration_tree_renderer")

describe("OrchestrationTreeRenderer", function()
  local original_get
  local statuses = {}

  ---@param path string
  ---@param bufnr number?
  ---@param children table[]?
  ---@return table
  local function node(path, bufnr, children)
    return { path = path, abs = "/repo/" .. path, bufnr = bufnr, children = children or {}, repeated = false }
  end

  before_each(function()
    original_get = ChatStatus.get
    statuses = {}
    ChatStatus.get = function(bufnr)
      return statuses[bufnr]
    end
  end)

  after_each(function()
    ChatStatus.get = original_get
  end)

  it("draws the branches and each chat's status", function()
    statuses = { [12] = "idle", [14] = "responding", [18] = "error" }

    local tree = node("root.md", 12, {
      node("b.md", 14),
      node("c.md", nil, { node("d.md", 18) }),
    })

    assert.same({
      "root.md (buffer 12) [idle]",
      "├─ b.md (buffer 14) [responding]",
      "└─ c.md [not open]",
      "   └─ d.md (buffer 18) [error]",
    }, Renderer.render(tree))
  end)

  it("keeps the rail under a branch that still has siblings below it", function()
    statuses = {}
    local tree = node("root.md", nil, {
      node("b.md", nil, { node("b1.md", nil) }),
      node("c.md", nil),
    })

    assert.same({
      "root.md [not open]",
      "├─ b.md [not open]",
      "│  └─ b1.md [not open]",
      "└─ c.md [not open]",
    }, Renderer.render(tree))
  end)

  it("says a buffer exists but is not attached rather than calling it idle", function()
    -- `idle` と書くとポーリングできる相手に見える
    local tree = node("root.md", 12)

    assert.same({ "root.md (buffer 12) [not attached]" }, Renderer.render(tree))
  end)

  it("marks the chat the command was run from", function()
    local tree = node("root.md", nil, { node("b.md", nil) })

    assert.same({
      "root.md [not open]",
      "└─ b.md [not open] ←",
    }, Renderer.render(tree, "/repo/b.md"))
  end)

  it("says a repeated node was already shown", function()
    local repeated = node("root.md", nil)
    repeated.repeated = true

    assert.same({
      "b.md [not open]",
      "└─ root.md [not open] (shown above)",
    }, Renderer.render(node("b.md", nil, { repeated })))
  end)

  it("renders nothing for a tree that could not be built", function()
    assert.same({}, Renderer.render(nil))
  end)
end)
