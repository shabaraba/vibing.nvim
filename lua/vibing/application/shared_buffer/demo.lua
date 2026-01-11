---Demo script for buffer change detection and multi-agent coordination
---This script demonstrates the basic functionality of the shared buffer system
local M = {}

local SharedBufferManager = require("vibing.application.shared_buffer.manager")
local NotificationDispatcher = require("vibing.application.shared_buffer.notification_dispatcher")

---デモを実行
function M.run_demo()
  print("=== Shared Buffer Demo ===\n")

  -- ステップ1: 共有バッファを作成
  print("Step 1: Creating shared buffer...")
  local bufnr = SharedBufferManager.get_or_create_shared_buffer()
  print(string.format("  ✓ Shared buffer created (bufnr: %d)\n", bufnr))

  -- ステップ2: Claude セッションを登録
  print("Step 2: Registering Claude sessions...")

  local notifications = {
    ["Claude-abc12"] = {},
    ["Claude-def34"] = {},
    ["Claude-xyz56"] = {},
  }

  for claude_id, _ in pairs(notifications) do
    NotificationDispatcher.register_session(claude_id, "session-" .. claude_id, bufnr, function(message)
      table.insert(notifications[claude_id], {
        from = message.from_claude_id,
        content = message.content,
        timestamp = os.date("%H:%M:%S"),
      })
      print(
        string.format(
          "  [%s] Notification received from Claude-%s",
          claude_id,
          message.from_claude_id
        )
      )
    end)
    print(string.format("  ✓ Registered %s", claude_id))
  end
  print("")

  -- ステップ3: メッセージを投稿
  print("Step 3: Posting messages...\n")

  -- Claude-abc12 が Claude-def34 にメンション
  print("  → Claude-abc12 mentions @Claude-def34")
  SharedBufferManager.append_message(
    "abc12",
    "ログイン機能の実装が完了しました。レビューお願いします。",
    { "Claude-def34" }
  )
  vim.wait(100)

  -- Claude-def34 が Claude-abc12 に返信
  print("  → Claude-def34 replies to @Claude-abc12")
  SharedBufferManager.append_message("def34", "確認しました。問題ありません。", { "Claude-abc12" })
  vim.wait(100)

  -- Claude-xyz56 が @All で全員にメッセージ
  print("  → Claude-xyz56 broadcasts to @All")
  SharedBufferManager.append_message("xyz56", "全体的な進捗を確認したいです。ステータスを教えてください。", { "All" })
  vim.wait(100)

  print("")

  -- ステップ4: 通知を確認
  print("Step 4: Checking notifications...\n")

  for claude_id, notifs in pairs(notifications) do
    print(string.format("  %s received %d notification(s):", claude_id, #notifs))
    for _, notif in ipairs(notifs) do
      print(string.format("    [%s] From Claude-%s", notif.timestamp, notif.from))
    end
  end

  print("\n=== Demo Complete ===\n")
  print("You can now:")
  print("  1. Open the shared buffer: :lua require('vibing.application.shared_buffer.manager').open_shared_buffer()")
  print("  2. View registered sessions: :lua vim.print(require('vibing.application.shared_buffer.notification_dispatcher').get_registered_sessions())")
  print("  3. Manually add messages to the shared buffer and observe notifications")
end

---クリーンアップ
function M.cleanup()
  SharedBufferManager.clear_shared_buffer()
  NotificationDispatcher.unregister_all()
  print("Demo cleanup complete")
end

return M
