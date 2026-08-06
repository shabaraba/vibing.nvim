local MoteFrontmatter = require("vibing.core.utils.mote.frontmatter")

describe("mote frontmatter", function()
  describe("get_dirs", function()
    it("returns mote_dirs arrays as-is", function()
      assert.same({ "/a", "/b" }, MoteFrontmatter.get_dirs({ mote_dirs = { "/a", "/b" } }))
    end)

    it("wraps a string mote_dirs into an array", function()
      assert.same({ "/a" }, MoteFrontmatter.get_dirs({ mote_dirs = "/a" }))
    end)

    it("falls back to mote_cwd when mote_dirs is missing", function()
      assert.same({ "/legacy" }, MoteFrontmatter.get_dirs({ mote_cwd = "/legacy" }))
    end)

    it("falls back to mote_cwd when mote_dirs is empty", function()
      assert.same({ "/legacy" }, MoteFrontmatter.get_dirs({ mote_dirs = {}, mote_cwd = "/legacy" }))
    end)

    it("prefers mote_dirs over mote_cwd", function()
      assert.same({ "/a" }, MoteFrontmatter.get_dirs({ mote_dirs = { "/a" }, mote_cwd = "/legacy" }))
    end)

    it("returns nil when nothing is configured", function()
      assert.is_nil(MoteFrontmatter.get_dirs({}))
      assert.is_nil(MoteFrontmatter.get_dirs({ mote_dirs = {} }))
      assert.is_nil(MoteFrontmatter.get_dirs(nil))
    end)
  end)
end)
