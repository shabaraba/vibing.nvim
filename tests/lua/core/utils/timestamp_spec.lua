local Timestamp = require("vibing.core.utils.timestamp")

describe("Timestamp header grammar", function()
  it("reads the plain and legacy User headers", function()
    assert.same({ kind = "User", unsent = true }, Timestamp.parse_header("## User <!-- unsent -->"))
    assert.equals("2026-09-02 08:13:11", Timestamp.parse_header("## User <!-- 2026-09-02 08:13:11 -->").timestamp)
    assert.equals("user", Timestamp.extract_role("## User"))
    assert.equals("assistant", Timestamp.extract_role("## Assistant"))
  end)

  it("reads a delivery header's kind and sender", function()
    local header = Timestamp.parse_header("## Report <!-- 2026-09-02 08:14:07 from .vibing/chat/worker.md -->")

    assert.equals("Report", header.kind)
    assert.equals("2026-09-02 08:14:07", header.timestamp)
    assert.equals(".vibing/chat/worker.md", header.from)
    assert.is_false(header.unsent)
  end)

  it("reports every delivery kind as the user role", function()
    -- セクションの中身はそのまま CLI へ送るプロンプトなので、別ロールにすると
    -- `extract_user_message` が拾わず、配達されたターンが送信されないまま消える
    for _, kind in ipairs({ "Request", "Report", "Notice" }) do
      local line = Timestamp.create_delivery_header(kind, ".vibing/chat/x.md")
      assert.equals("user", Timestamp.extract_role(line), line)
      assert.is_true(Timestamp.is_delivery_header(line))
      assert.is_true(Timestamp.is_unsent_header(line))
    end
  end)

  it("round-trips what it writes", function()
    local unsent = Timestamp.create_delivery_header("Request", ".vibing/chat/boss.md")
    assert.equals("## Request <!-- unsent from .vibing/chat/boss.md -->", unsent)

    local sent = Timestamp.create_delivery_header("Report", nil, "2026-09-02 08:14:07")
    assert.equals("## Report <!-- 2026-09-02 08:14:07 -->", sent)
    assert.is_nil(Timestamp.parse_header(sent).from)
    assert.equals("2026-09-02 08:14:07", Timestamp.extract_timestamp_from_comment(sent))
  end)

  it("refuses to write a kind nothing can read back", function()
    assert.has_error(function()
      Timestamp.create_delivery_header("Whatever", nil)
    end)
  end)

  it("is not a header for an unrelated heading", function()
    assert.is_nil(Timestamp.parse_header("## Modified Files"))
    assert.is_nil(Timestamp.parse_header("### From .vibing/chat/x.md (chat buffer 3)"))
    assert.is_false(Timestamp.is_header("Some prose about ## User"))
  end)

  it("keeps the section when the comment is unreadable", function()
    -- ここは表示のための分解。壊れたコメント1つでセクションそのものが行方不明になるほうが害が大きい
    local header = Timestamp.parse_header("## Report <!-- who knows -->")

    assert.equals("Report", header.kind)
    assert.is_nil(header.timestamp)
    assert.is_false(header.unsent)
  end)
end)
