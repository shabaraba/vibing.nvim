local SendMessage = require("vibing.application.chat.send_message")

describe("send_message._merge_modified_files", function()
  it("resolves mote-relative paths against each batch's own base", function()
    local result = SendMessage._merge_modified_files({
      { base = "/repo/workspaces/app-a", files = { "src/main.lua" } },
      { base = "/repo/workspaces/app-b", files = { "src/main.lua" } },
    }, nil)

    -- 別mote_dirsの同名相対パスが衝突せず両方残ること
    assert.same({
      "/repo/workspaces/app-a/src/main.lua",
      "/repo/workspaces/app-b/src/main.lua",
    }, result)
  end)

  it("keeps absolute mote paths as-is", function()
    local result = SendMessage._merge_modified_files({
      { base = "/repo", files = { "/repo/src/a.lua", "src/b.lua" } },
    }, nil)

    assert.same({ "/repo/src/a.lua", "/repo/src/b.lua" }, result)
  end)

  it("unions tool-event paths and dedupes against mote results", function()
    local result = SendMessage._merge_modified_files({
      { base = "/repo", files = { "src/a.lua" } },
    }, {
      ["/repo/src/a.lua"] = true,
      ["/repo/src/only-tool-event.lua"] = true,
    })

    assert.equals(2, #result)
    assert.equals("/repo/src/a.lua", result[1])
    assert.equals("/repo/src/only-tool-event.lua", result[2])
  end)

  it("handles empty inputs", function()
    assert.same({}, SendMessage._merge_modified_files({}, nil))
    assert.same({}, SendMessage._merge_modified_files(nil, {}))
  end)

  it("strips trailing slashes from batch bases", function()
    local result = SendMessage._merge_modified_files({
      { base = "/repo/dir/", files = { "x.lua" } },
    }, nil)

    assert.same({ "/repo/dir/x.lua" }, result)
  end)
end)
