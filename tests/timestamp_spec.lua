-- Tests for vibing.utils.timestamp module

describe("vibing.utils.timestamp", function()
  local Timestamp

  before_each(function()
    -- Clear loaded modules
    package.loaded["vibing.utils.timestamp"] = nil

    -- Mock vim.notify to prevent actual notifications during tests
    _G.vim = _G.vim or {}
    _G.vim.notify = function() end
    _G.vim.log = { levels = { WARN = 1, ERROR = 2 } }

    -- Load the module
    Timestamp = require("vibing.utils.timestamp")
  end)

  describe("now()", function()
    it("タイムスタンプ文字列を返す", function()
      local timestamp = Timestamp.now()
      assert.is_string(timestamp)
      assert.is_not_nil(timestamp:match("%d%d%d%d%-%d%d%-%d%d %d%d:%d%d:%d%d"))
    end)

    it("正しいフォーマットでタイムスタンプを生成する", function()
      local timestamp = Timestamp.now()
      -- YYYY-MM-DD HH:MM:SS形式にマッチすることを確認
      local year, month, day, hour, min, sec = timestamp:match("^(%d%d%d%d)%-(%d%d)%-(%d%d) (%d%d):(%d%d):(%d%d)$")
      assert.is_not_nil(year)
      assert.is_not_nil(month)
      assert.is_not_nil(day)
      assert.is_not_nil(hour)
      assert.is_not_nil(min)
      assert.is_not_nil(sec)
    end)
  end)

  describe("create_header()", function()
    it("Userロールのタイムスタンプ付きヘッダーを生成する", function()
      local header = Timestamp.create_header("User", "2025-12-27 14:30:00")
      assert.equals("## 2025-12-27 14:30:00 User", header)
    end)

    it("Assistantロールのタイムスタンプ付きヘッダーを生成する", function()
      local header = Timestamp.create_header("Assistant", "2025-12-27 14:35:00")
      assert.equals("## 2025-12-27 14:35:00 Assistant", header)
    end)

    it("タイムスタンプ省略時は現在時刻を使用する", function()
      local header = Timestamp.create_header("User")
      assert.is_not_nil(header:match("^## %d%d%d%d%-%d%d%-%d%d %d%d:%d%d:%d%d User$"))
    end)

    it("無効なロールでエラーを投げる", function()
      assert.has_error(function()
        Timestamp.create_header("InvalidRole")
      end)
    end)

    it("nilロールでエラーを投げる", function()
      assert.has_error(function()
        Timestamp.create_header(nil)
      end)
    end)
  end)

  describe("extract_role()", function()
    it("タイムスタンプ付きUserヘッダーからロールを抽出する", function()
      local role = Timestamp.extract_role("## 2025-12-27 14:30:00 User")
      assert.equals("user", role)
    end)

    it("タイムスタンプ付きAssistantヘッダーからロールを抽出する", function()
      local role = Timestamp.extract_role("## 2025-12-27 14:35:00 Assistant")
      assert.equals("assistant", role)
    end)

    it("レガシー形式（タイムスタンプなし）のUserヘッダーからロールを抽出する", function()
      local role = Timestamp.extract_role("## User")
      assert.equals("user", role)
    end)

    it("レガシー形式（タイムスタンプなし）のAssistantヘッダーからロールを抽出する", function()
      local role = Timestamp.extract_role("## Assistant")
      assert.equals("assistant", role)
    end)

    it("ロールを小文字で返す", function()
      local role1 = Timestamp.extract_role("## User")
      local role2 = Timestamp.extract_role("## Assistant")
      assert.equals("user", role1)
      assert.equals("assistant", role2)
    end)

    it("ヘッダーでない行に対してnilを返す", function()
      assert.is_nil(Timestamp.extract_role("Normal text"))
      assert.is_nil(Timestamp.extract_role("# Single hash"))
      assert.is_nil(Timestamp.extract_role(""))
    end)
  end)

  describe("has_timestamp()", function()
    it("タイムスタンプ付きヘッダーに対してtrueを返す", function()
      assert.is_true(Timestamp.has_timestamp("## 2025-12-27 14:30:00 User"))
      assert.is_true(Timestamp.has_timestamp("## 2025-12-27 14:35:00 Assistant"))
    end)

    it("レガシー形式ヘッダーに対してfalseを返す", function()
      assert.is_false(Timestamp.has_timestamp("## User"))
      assert.is_false(Timestamp.has_timestamp("## Assistant"))
    end)

    it("非ヘッダー行に対してfalseを返す", function()
      assert.is_false(Timestamp.has_timestamp("Normal text"))
      assert.is_false(Timestamp.has_timestamp(""))
    end)
  end)

  describe("extract_timestamp()", function()
    it("タイムスタンプ付きヘッダーからタイムスタンプを抽出する", function()
      local timestamp = Timestamp.extract_timestamp("## 2025-12-27 14:30:00 User")
      assert.equals("2025-12-27 14:30:00", timestamp)
    end)

    it("レガシー形式ヘッダーに対してnilを返す", function()
      assert.is_nil(Timestamp.extract_timestamp("## User"))
      assert.is_nil(Timestamp.extract_timestamp("## Assistant"))
    end)

    it("非ヘッダー行に対してnilを返す", function()
      assert.is_nil(Timestamp.extract_timestamp("Normal text"))
    end)
  end)

  describe("is_header()", function()
    it("タイムスタンプ付きヘッダーに対してtrueを返す", function()
      assert.is_true(Timestamp.is_header("## 2025-12-27 14:30:00 User"))
      assert.is_true(Timestamp.is_header("## 2025-12-27 14:35:00 Assistant"))
    end)

    it("レガシー形式ヘッダーに対してtrueを返す", function()
      assert.is_true(Timestamp.is_header("## User"))
      assert.is_true(Timestamp.is_header("## Assistant"))
    end)

    it("非ヘッダー行に対してfalseを返す", function()
      assert.is_false(Timestamp.is_header("Normal text"))
      assert.is_false(Timestamp.is_header("# Single hash"))
      assert.is_false(Timestamp.is_header(""))
      assert.is_false(Timestamp.is_header("## InvalidRole"))
    end)
  end)

  describe("後方互換性", function()
    it("タイムスタンプあり/なし両形式を同じように処理できる", function()
      local role1 = Timestamp.extract_role("## User")
      local role2 = Timestamp.extract_role("## 2025-12-27 14:30:00 User")
      assert.equals(role1, role2)

      local is_header1 = Timestamp.is_header("## Assistant")
      local is_header2 = Timestamp.is_header("## 2025-12-27 14:35:00 Assistant")
      assert.equals(is_header1, is_header2)
    end)
  end)

  describe("エッジケース", function()
    it("空文字列を適切に処理する", function()
      assert.is_nil(Timestamp.extract_role(""))
      assert.is_false(Timestamp.is_header(""))
      assert.is_false(Timestamp.has_timestamp(""))
      assert.is_nil(Timestamp.extract_timestamp(""))
    end)

    it("不完全なタイムスタンプを拒否する", function()
      assert.is_nil(Timestamp.extract_role("## 2025-12-27 User"))
      assert.is_nil(Timestamp.extract_role("## 14:30:00 User"))
      assert.is_false(Timestamp.has_timestamp("## 2025-12-27 User"))
    end)

    it("ヘッダー前後の空白を考慮しない", function()
      -- パターンは行頭(^)から始まるため、前方の空白がある場合はマッチしない
      assert.is_nil(Timestamp.extract_role("  ## User"))
      assert.is_false(Timestamp.is_header("  ## User"))
    end)
  end)
end)
