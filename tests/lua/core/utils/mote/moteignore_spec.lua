local Moteignore = require("vibing.core.utils.mote.moteignore")

describe("moteignore", function()
  local tmp_dir

  before_each(function()
    tmp_dir = vim.fn.tempname()
    vim.fn.mkdir(tmp_dir, "p")
  end)

  after_each(function()
    vim.fn.delete(tmp_dir, "rf")
  end)

  describe("add_vibing_ignore", function()
    it("adds .vibing/ (and never a separate .worktrees/ rule) to an ignore file lacking it", function()
      local ignore_path = tmp_dir .. "/ignore"
      vim.fn.writefile({
        "# Uses gitignore syntax",
        "",
        "node_modules/",
      }, ignore_path)

      Moteignore.add_vibing_ignore(tmp_dir)

      local content = table.concat(vim.fn.readfile(ignore_path), "\n")
      assert.is_true(content:match("%.vibing/") ~= nil)
      assert.is_nil(content:match("%.worktrees/"))
    end)

    it("does not duplicate .vibing/ if already present", function()
      local ignore_path = tmp_dir .. "/ignore"
      vim.fn.writefile({
        "# Uses gitignore syntax",
        "",
        ".vibing/",
      }, ignore_path)

      Moteignore.add_vibing_ignore(tmp_dir)

      local lines = vim.fn.readfile(ignore_path)
      local count = 0
      for _, line in ipairs(lines) do
        if line == ".vibing/" then
          count = count + 1
        end
      end
      assert.equals(1, count)
    end)

    it("does nothing when the ignore file does not exist", function()
      Moteignore.add_vibing_ignore(tmp_dir)
      assert.equals(0, vim.fn.filereadable(tmp_dir .. "/ignore"))
    end)
  end)
end)
