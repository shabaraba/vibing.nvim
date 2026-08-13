describe("limit_state", function()
  local LimitState = require("vibing.infrastructure.storage.limit_state")

  local tmp_root

  before_each(function()
    tmp_root = vim.fn.tempname()
    vim.fn.mkdir(tmp_root, "p")
    LimitState.clear_cache()
  end)

  after_each(function()
    if tmp_root then
      vim.fn.delete(tmp_root, "rf")
    end
  end)

  it("returns nil when no store exists", function()
    assert.is_nil(LimitState.load(tmp_root))
  end)

  it("records a reset time and reads it back", function()
    local resets_at = os.time() + 3600
    assert.is_true(LimitState.record({ resets_at = resets_at, limit_type = "five_hour" }, tmp_root))

    local state = LimitState.load(tmp_root)
    assert.is_not_nil(state)
    assert.equals(resets_at, state.resets_at)
    assert.equals("five_hour", state.limit_type)
    assert.is_number(state.observed_at)
  end)

  it("ignores rate limit info that carries no reset time", function()
    -- The hook and error-text channels report a rejection without a timestamp; such a record
    -- cannot answer "is the limit still active", so storing it would be worse than nothing.
    assert.is_false(LimitState.record({ limit_type = "five_hour" }, tmp_root))
    assert.is_nil(LimitState.load(tmp_root))
  end)

  it("reports an active limit while the reset is in the future", function()
    LimitState.record({ resets_at = os.time() + 600 }, tmp_root)
    assert.is_not_nil(LimitState.get_active(tmp_root))
  end)

  it("reports no active limit once the reset has passed", function()
    LimitState.record({ resets_at = os.time() - 1 }, tmp_root)
    assert.is_nil(LimitState.get_active(tmp_root))
  end)

  it("clears the record", function()
    LimitState.record({ resets_at = os.time() + 600 }, tmp_root)
    LimitState.clear(tmp_root)
    assert.is_nil(LimitState.load(tmp_root))
    assert.is_nil(LimitState.get_active(tmp_root))
  end)

  it("clearing a store that does not exist is a no-op", function()
    LimitState.clear(tmp_root)
    assert.is_nil(LimitState.load(tmp_root))
  end)

  it("ignores a corrupt store instead of erroring", function()
    local path = LimitState.get_path(tmp_root)
    vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
    vim.fn.writefile({ "{ not json" }, path)

    assert.is_nil(LimitState.load(tmp_root))
  end)

  it("stores under .vibing/limit-state.json", function()
    assert.is_truthy(LimitState.get_path(tmp_root):find("/%.vibing/limit%-state%.json$"))
  end)
end)
