local notify = require("vibing.utils.notify")

---@class Vibing.Commands
---ユーザーコマンドから呼び出される関数群
---各関数はactions.chatやactions.inlineモジュールに処理を委譲
local M = {}

---チャットウィンドウを開く
---:VibingChatコマンドから呼び出される
---既存のチャットバッファがある場合は再表示、ない場合は新規作成
function M.chat()
  require("vibing.actions.chat").open()
end

---チャットウィンドウを閉じる
---:VibingCloseChatコマンドから呼び出される
---ウィンドウのみ閉じてバッファは保持（再度開くと会話継続可能）
function M.chat_close()
  require("vibing.actions.chat").close()
end

---チャットウィンドウをトグル
---:VibingToggleChatコマンドから呼び出される
---開いている場合は閉じ、閉じている場合は開く
function M.chat_toggle()
  require("vibing.actions.chat").toggle()
end

---選択範囲のコードを修正
---:VibingFixコマンドから呼び出される
---ビジュアル選択範囲に対してバグ修正・問題解決を実行（Editツール使用）
function M.fix()
  require("vibing.actions.inline").execute("fix")
end

---選択範囲に機能を追加
---:VibingFeatコマンドから呼び出される
---ビジュアル選択範囲に対して新機能実装を実行（Edit, Writeツール使用）
function M.feat()
  require("vibing.actions.inline").execute("feat")
end

---選択範囲のコードを説明
---:VibingExplainコマンドから呼び出される
---ビジュアル選択範囲のコードをフローティングウィンドウで解説（読み取り専用）
function M.explain()
  require("vibing.actions.inline").execute("explain")
end

---選択範囲のコードをリファクタリング
---:VibingRefactorコマンドから呼び出される
---ビジュアル選択範囲の可読性・保守性を改善（Editツール使用）
function M.refactor()
  require("vibing.actions.inline").execute("refactor")
end

---選択範囲のテストを生成
---:VibingTestコマンドから呼び出される
---ビジュアル選択範囲のコードに対するテストコードを生成（Edit, Writeツール使用）
function M.test()
  require("vibing.actions.inline").execute("test")
end

---カスタムプロンプトを実行（結果をフローティングウィンドウ表示）
---:VibingAskコマンドから呼び出される
---自然言語指示を実行し、結果を読み取り専用バッファで表示（コード変更なし）
---@param prompt string 自然言語での指示内容（例: "このコードの複雑度を分析して"）
function M.ask(prompt)
  require("vibing.actions.inline").custom(prompt, true)
end

---カスタムプロンプトを実行（コード直接変更）
---:VibingCustomコマンドから呼び出される
---自然言語指示を実行し、結果を直接コードに反映（Edit, Writeツール使用可能）
---@param prompt string 自然言語での指示内容（例: "エラーハンドリングを追加"）
function M.do_action(prompt)
  require("vibing.actions.inline").custom(prompt, false)
end

---ファイルをコンテキストに追加
---:VibingContextコマンドから呼び出される
---指定されたファイルを次回のプロンプトに含めるコンテキストとして登録
---pathがnilの場合は現在のバッファを追加
---@param path? string ファイルパス（省略時は現在のバッファ）
function M.add_context(path)
  require("vibing.context").add(path)
end

---登録済みコンテキストを全てクリア
---:VibingClearContextコマンドから呼び出される
---手動で追加されたコンテキストファイルをすべて削除
---自動コンテキスト（開いているバッファ）は設定に従い継続
function M.clear_context()
  require("vibing.context").clear()
end

---実行中のリクエストをキャンセル
---:VibingCancelコマンドから呼び出される
---現在のアダプターで実行中のストリーミングまたは非同期リクエストを中断
---成功時にはキャンセル通知を表示
function M.cancel()
  local vibing = require("vibing")
  local adapter = vibing.get_adapter()
  if adapter then
    local cancelled = adapter:cancel()
    if cancelled then
      notify.info("Cancelled")
    end
  end
end

return M
