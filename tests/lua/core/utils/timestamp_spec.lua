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
      local line = Timestamp.create_header(kind, nil, ".vibing/chat/x.md")
      assert.equals("user", Timestamp.extract_role(line), line)
      assert.equals(kind, Timestamp.parse_header(line).kind)
      assert.is_true(Timestamp.is_unsent_header(line))
    end
  end)

  it("round-trips what it writes", function()
    local unsent = Timestamp.create_header("Request", nil, ".vibing/chat/boss.md")
    assert.equals("## Request <!-- unsent from .vibing/chat/boss.md -->", unsent)

    local sent = Timestamp.create_header("Report", "2026-09-02 08:14:07")
    assert.equals("## Report <!-- 2026-09-02 08:14:07 -->", sent)
    assert.is_nil(Timestamp.parse_header(sent).from)
    assert.equals("2026-09-02 08:14:07", Timestamp.extract_timestamp_from_comment(sent))
  end)

  it("writes the plain User header through the same constructor", function()
    assert.equals("## User <!-- unsent -->", Timestamp.create_unsent_user_header())
    assert.equals("## User <!-- 2026-09-02 08:13:11 -->", Timestamp.create_user_header_with_timestamp("2026-09-02 08:13:11"))
  end)

  it("refuses to write a kind nothing can read back", function()
    assert.has_error(function()
      Timestamp.create_header("Whatever")
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

  it("builds a stamped Assistant header, which is what records a turn's end", function()
    local header = Timestamp.create_header("Assistant", "2026-09-04 10:05:00")

    assert.equals("## Assistant <!-- 2026-09-04 10:05:00 -->", header)
    assert.equals("2026-09-04 10:05:00", Timestamp.parse_header(header).timestamp)
    assert.equals("assistant", Timestamp.extract_role(header))
  end)

  it("reads a stamp back as the local time `now` wrote it as", function()
    local now = os.time()
    local stamp = os.date("%Y-%m-%d %H:%M:%S", now)

    assert.equals(now, Timestamp.to_epoch(stamp))
  end)

  it("returns nothing for anything that is not a full stamp", function()
    assert.is_nil(Timestamp.to_epoch("unsent"))
    assert.is_nil(Timestamp.to_epoch("2026-09-04 10:05"))
    assert.is_nil(Timestamp.to_epoch(nil))
  end)
end)
