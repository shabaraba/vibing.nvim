local Context = require("vibing.application.context.manager")
local WindowManager = require("vibing.presentation.chat.modules.window_manager")
local FileManager = require("vibing.presentation.chat.modules.file_manager")
local FrontmatterHandler = require("vibing.presentation.chat.modules.frontmatter_handler")
local Renderer = require("vibing.presentation.chat.modules.renderer")
local StreamingHandler = require("vibing.presentation.chat.modules.streaming_handler")
local ConversationExtractor = require("vibing.presentation.chat.modules.conversation_extractor")
local TurnRegistry = require("vibing.infrastructure.adapter.modules.turn_registry")
local KeymapHandler = require("vibing.presentation.chat.modules.keymap_handler")
local Fs = require("vibing.core.utils.fs")

---@class Vibing.ChatBuffer
---@field buf number?
---@field win number?
---@field config Vibing.ChatConfig
---@field session_id string?
---@field file_path string?
---@field session Vibing.ChatSession? セッションオブジェクト（非推奨、後方互換性のため）
---@field _chunk_parts string[] 未フラッシュのチャンク片。連結は流すときに1回だけ行う
---@field _chunk_timer any チャンクフラッシュ用のタイマー
---@field _pending_choices table[]? add_user_section()後に挿入する選択肢
---@field _pending_approvals table[]? add_user_section()後に挿入する承認要求UI。**複数**
---  なのは、CLIが1ターンに複数のPreToolUseフックを並列に起動するから（実測: claudeで3本が
---  0.54秒差で立ち上がり、全体が重なる）。表示順に並べる
---@field _approvals_rendered_unsent boolean? 末尾の未送信セクションに承認プロンプトが描いてある。
---  ターン途中で描けるようになった（#778）ぶん、ターンの終わりが同じものを描き直して二重に
---  ならないための印
---@field _pending_user_text string? 次のadd_user_section()で本文として差し込むテキスト
---@field _current_turn_id string? 待っているターンのID（chunk / response の staleness 判定）
---@field _current_process_id string? そのターンを走らせているCLIプロセスのID（kill対象）。
---  ターンIDとは別に持つ必要がある: `cancel_request` はターンが終わった後にもゾンビ回収として
---  呼ばれる（`send_message` 冒頭）ので、その時点ではレジストリにターンのエントリが無く、
---  ターンIDからプロセスを引き直すことはできない
---@field _current_adapter table? per-chatアダプター（フロントマターagent指定時）
---@field _is_sending boolean 送信処理中かどうか（Enter連打による重複送信防止）
---@field _stop_reason "waiting_approval"|"asked_question"|"error"|nil 直前のターンが止まった理由
---@field _session_allow table セッションレベルの許可リスト
---@field _session_deny table セッションレベルの拒否リスト
---@field _once_tools table? 一時許可/拒否ツールのトラッキング（次のメッセージでクリア）
local ChatBuffer = {}
ChatBuffer.__index = ChatBuffer

---@param config Vibing.ChatConfig
---@return Vibing.ChatBuffer
function ChatBuffer:new(config)
  local instance = setmetatable({}, ChatBuffer)
  instance.buf = nil
  instance.win = nil
  instance.config = config
  instance.session_id = nil
  instance.file_path = nil
  instance.session = nil
  instance._chunk_parts = {}
  instance._chunk_timer = nil
  instance._pending_choices = nil
  instance._pending_approvals = {}
  instance._current_turn_id = nil
  instance._current_process_id = nil
  instance._current_adapter = nil
  instance._is_sending = false
  instance._stop_reason = nil
  instance._session_allow = {}
  instance._session_deny = {}
  instance._once_tools = nil
  return instance
end

--- 現在のリクエストに対応するアダプターを取得（per-chat優先、なければグローバル）
---@return table|nil
function ChatBuffer:_get_active_adapter()
  if self._current_adapter then
    return self._current_adapter
  end
  local vibing = require("vibing")
  return vibing.get_adapter()
end

---チャットウィンドウを開く
function ChatBuffer:open()
  if self:is_open() then
    vim.api.nvim_set_current_win(self.win)
    return
  end

  local buffer_existed = self.buf and vim.api.nvim_buf_is_valid(self.buf)
  local has_content = false

  if buffer_existed then
    local line_count = vim.api.nvim_buf_line_count(self.buf)
    has_content = line_count > 1
      or (line_count == 1 and vim.api.nvim_buf_get_lines(self.buf, 0, 1, false)[1] ~= "")
  end

  self:_create_buffer()
  self:_create_window()
  self:_setup_keymaps()

  if not has_content then
    local cursor_line = Renderer.init_content(self.buf, self.session)
    if self:is_open() and vim.api.nvim_win_is_valid(self.win) and cursor_line > 0 then
      pcall(vim.api.nvim_win_set_cursor, self.win, { cursor_line, 0 })
    end
  end
end

---いまこのチャットが、答えを待たせているフックを1本でも持っているか
---
---**`_pending_approvals` が空かどうかではない。** あちらは描画リストで、kill する経路では
---答えたあとも残る（プロセスはとうに死んでいるので、残っていても誰も待っていない）。
---「待たせているか」を訊く場所はレジストリのほうで、答えが出た瞬間に空になるので古くならない
---— `chat_status` が `_stop_reason` ではなくこちらを読むのと同じ理由
---@return boolean
function ChatBuffer:_has_blocked_approvals()
  return require("vibing.infrastructure.rpc.pending_approvals").has_for_chat(self.buf)
end

---このチャットが止めているフックを、答えないまま全部解放する
---
---答えではないので deny が書かれる。呼ぶのは「このターンはもう答えを届けられない」と分かった
---側 — 打ち切り（`cancel_request`）と、ターンの終わり（`_finish_turn`、CLIが先に死んだ場合）。
---
---**プロンプトの行は消さない。** kill する経路では答えたあとも残るのが従来の挙動で、ユーザーは
---後から答えて新しいターンとして再試行できる。ここで消すと、その経路の挙動まで黙って変わる
---@param reason string フックに渡す拒否理由
---@return number released 実際に解放した件数。kill する経路では常に0
function ChatBuffer:_release_blocked_approvals(reason)
  local released = 0
  pcall(function()
    released = require("vibing.infrastructure.rpc.pending_approvals").resolve_for_chat(self.buf, reason)
  end)
  return released
end

---最後のブロックが解けたので、入力欄を閉じてアシスタントの続きに戻す
---
---**答えられた場合と期限切れの両方がここに合流する。** どちらも「このチャットはもうフックを
---止めていない」であって、そこから先に要ることは同じ:
---
---1. プロンプトを描いた未送信セクションを閉じる。開いたままだと `extract_user_message` が
---   そこを読む — **未送信かどうかは見ていない**（`extract_role` は `Assistant` 以外の Kind
---   すべてに `user` を返す）ので、閉じずに下へ出力を積むと、アシスタントの文章が
---   ユーザーの次のメッセージとして送り返される
---2. `## Assistant` を開く。ここで未送信の `## User` を開くと 1 と同じ壊れ方に戻る
---3. **溜めていた出力を流す。** 未送信セクションが末尾にあるあいだ `_flush_chunks` は積めない
---   ので、閉じたこの瞬間が唯一の出口になる
---
---`_approvals_rendered_unsent` を条件にしているのは、描いていないのにセクションを閉じたり
---`## Assistant` を開いたりしないため（テストや kill 経路から呼ばれても何もしない）
---@return boolean resumed
function ChatBuffer:_resume_after_approvals()
  if not self._approvals_rendered_unsent then
    return false
  end
  if self:_has_blocked_approvals() then
    return false
  end

  ConversationExtractor.commit_user_message(self.buf)
  self._approvals_rendered_unsent = false

  -- 停止理由もここで捨てる。普段これを捨てるのは**次のターンが走り出す場所**だが、その場で
  -- 答える経路も期限切れも新しいターンを始めない。残すと、ターンが終わったあとも次の送信まで
  -- `waiting_approval` を名乗り続ける — 答えるものが1つも無いのに、である
  if self._stop_reason == "waiting_approval" then
    self._stop_reason = nil
  end

  self:start_response()
  self:_flush_chunks()
  return true
end

---1ターンの締めくくり
---
---`_handle_response` の完了経路は4つある（セッション破損 / mote finalize / ファイル変更なし /
---git patch finalize、うち2つは `vim.schedule` の中）が、すべてここに合流する。しかも turn_id
---不一致による早期returnより後なので、キャンセル済みの古いターンが遅れて完了しても飛ばない。
---
---`ChatBuffer:add_user_section()` 本体と分けてあるのは、そちらがスラッシュコマンド経路からも
---呼ばれるから。混ぜるとAIターンが1回も走っていないのに完了が飛ぶ
function ChatBuffer:_finish_turn()
  -- ターンが終わったのにまだ止まっているフックがあるなら、CLIのほうが先に死んだということ
  -- （承認待ちのフックはターンを終わらせないので、正常系ではここは0件）。親を失ったフックは
  -- もう誰にも答えられないので、ここで deny を書いて解放する。放っておいても上限が拾うが、
  -- それは15分後に「900秒答えられなかった」という、実際とは違う説明が出るということ。
  --
  -- 溜めているチャンクは**捨てない**。このターンの出力で、行き先は直後の `add_user_section`
  self:_release_blocked_approvals("The turn this approval belonged to ended before it was answered.")

  -- プロンプトがターン途中で既に描かれているなら、その未送信セクションごと落とす。下の
  -- `add_user_section` が同じ保留を描き直すので、残すと同じ承認が2つ並び、答えられるのは
  -- 片方だけという状態になる。落として描き直すのは、溜まっている出力の行き先を作るためでも
  -- ある（`_flush_chunks` は末尾に追記するので、入力欄が末尾にあるうちは積めない）
  if self._approvals_rendered_unsent then
    ConversationExtractor.drop_trailing_unsent_section(self.buf, true)
    self._approvals_rendered_unsent = false
  end

  -- アシスタントヘッダーへの終了時刻はここで入れる。AIターンが走ったことが確かなのは
  -- この合流点だけ
  StreamingHandler.stamp_response_end(self.buf, self._assistant_header_line)
  self._assistant_header_line = nil
  self:add_user_section()
  -- ターンの締めくくり（終了時刻と `### Tokens`）が入ったあとに保存する。
  -- `update_session_id` の自動保存はこれより前に走るので、それだけに任せると
  -- ディスク上のチャットは常に1ターン遅れ、期限切れ判定が読むのは前のターンの数字になる
  self:save_after_turn()
  -- autocmd を挟むのは、ユーザーが自分の設定からも拾えるようにするため。
  -- `CompletionNotifier` 自身もこの経路で購読している
  vim.api.nvim_exec_autocmds("User", {
    pattern = "VibingResponseDone",
    data = { bufnr = self.buf },
  })
end

---実行中のリクエストを止める
---
---`adapter:cancel` は `wrapped_on_done` を同期で呼ぶので、ターンIDの後始末（`_current_turn_id`
---を落とす）はここではしない。`_handle_response` の turn_id 一致判定より先に消すと、
---キャンセルした当のターンの後始末が「別のターンの応答」として捨てられる。
---捨てたい呼び出し元（`close` / `send_message`）が、戻ってきてから自分で消す
---@return boolean cancelled 止めるものがあったか
function ChatBuffer:cancel_request()
  -- **保留中の承認を先に手放す（#778）。** 止めようとしているターンは、フックの中で `.res` を
  -- 待って止まっているかもしれない。止めたあとのCLIはもう待つのをやめる主体になれないので、
  -- 順序は `VimLeavePre` / `BufUnload` と同じ。
  --
  -- 早期returnより前に置くのは、止めるプロセスが見つからない場合でも保留が残るのは同じだから。
  -- 止まっていないのに答えを待たせ続けるほうが、返り値が変わらないことより重い
  if self:_release_blocked_approvals("The turn this approval belonged to was cancelled.") > 0 then
    -- 溜めていたチャンクは打ち切られたターンの続きで、書き戻す場所が無い。次の送信から来たなら
    -- 未送信セクションにユーザーの本文が入っていて、その下に積むのは `extract_user_message` が
    -- 拾う壊れ方そのもの。実際に解放したときだけ触るので、kill する経路は素通りする
    self._chunk_parts = {}
  end

  if not self._current_process_id then
    return false
  end

  local adapter = self:_get_active_adapter()
  if not adapter then
    return false
  end

  -- `stop_turn`, not `cancel`: the user asked for this request to stop, not for the conversation's
  -- CLI process to be thrown away. On the oneshot transport the two are the same thing anyway.
  adapter:stop_turn(self._current_process_id)
  return true
end

---チャットウィンドウを閉じる
function ChatBuffer:close()
  -- 実行中のリクエストをキャンセル
  self:cancel_request()
  self._current_turn_id = nil
  self._current_process_id = nil
  self._current_adapter = nil

  if self._chunk_timer then
    vim.fn.timer_stop(self._chunk_timer)
    self._chunk_timer = nil
  end
  if self.win and vim.api.nvim_win_is_valid(self.win) then
    if self.config.window.position == "current" then
      local alt_buf = vim.fn.bufnr("#")
      if alt_buf ~= -1 and vim.api.nvim_buf_is_valid(alt_buf) and alt_buf ~= self.buf then
        vim.api.nvim_win_set_buf(self.win, alt_buf)
      else
        local new_buf = vim.api.nvim_create_buf(true, false)
        vim.api.nvim_win_set_buf(self.win, new_buf)
      end
    else
      local win_count = #vim.api.nvim_list_wins()
      if win_count > 1 then
        vim.api.nvim_win_close(self.win, true)
      end
    end
  end
  self.win = nil
end

---ウィンドウが開いているか
---@return boolean
function ChatBuffer:is_open()
  return self.win ~= nil and vim.api.nvim_win_is_valid(self.win)
end

---メイン応答がストリーミング中かどうか
---summarize/set_file_titleなど、同一session_idに対して並行で--resumeを叩くと
---競合しうる処理は、送信前にこれをチェックしてブロックする
---@return boolean
function ChatBuffer:is_sending()
  return self._is_sending == true
end

---このチャットがリクエストを実行中か（送信開始からCLI終了まで）
---
---`_is_sending`は<CR>からCLI起動までの隙間をカバーする。`_current_turn_id`はその後だが、
---応答完了時にクリアされない（次のsend_message()でkillしてゾンビプロセスを刈るため意図的に
---残している）ので、存在だけを見ると1ターン目以降ずっと"responding"になる。
---実行中かどうかはTurnRegistryが唯一の答えを持っている: 全アダプタがstream開始で
---`open`し、on_doneで`close`する。
---
---既知の隙間: _handle_responseは`### Modified Files`と次の`## User`をvim.schedule越しに
---書くので、その1ティックのあいだidleを返す。応答本文はこの時点で完成しているのでdiff脚注
---だけの話。旧実装はこの窓も"responding"にできていたが、それは1ターン目以降ずっとtrueだった
---からで、代償が大きすぎた。
---@return boolean
function ChatBuffer:is_responding()
  if self:is_sending() then
    return true
  end
  if not self._current_turn_id then
    return false
  end
  return TurnRegistry.get(self._current_turn_id) ~= nil
end

---このターンがエラーで終わったことを記録する
---
---`send_message.lua` の `_handle_response` から呼ばれる。ターンが終わったこと自体は
---`add_user_section` ラッパーで分かるが、**なぜ**止まったかはそこからは見えない
function ChatBuffer:mark_turn_error()
  self._stop_reason = "error"
end

---直前のターンが止まった理由。実行中かどうかは含まない（`chat_status` が先に
---`is_responding()` を見る）
---
---3つの書き込み口（ここに挙げた `mark_turn_error` と、`insert_choices` /
---`insert_approval_request`）はいずれも**その事実が起きた時点で**書く。ターン終了時に
---まとめて判定する形にすると、`add_user_section()` が `_pending_choices` を消すより先に
---走らせるという順序の制約を、呼び出し側に守らせることになる。
---後勝ちで問題ないのは、質問も承認要求もそこでターンが止まるから
---@return "waiting_approval"|"asked_question"|"error"|nil
function ChatBuffer:get_stop_reason()
  return self._stop_reason
end

---バッファを作成
function ChatBuffer:_create_buffer()
  if self.buf and vim.api.nvim_buf_is_valid(self.buf) then
    return
  end

  self.buf = vim.api.nvim_create_buf(true, false)
  vim.bo[self.buf].modifiable = true
  vim.bo[self.buf].swapfile = false

  if self.file_path then
    vim.api.nvim_buf_set_name(self.buf, self.file_path)
  else
    local save_path = FileManager.get_save_directory(self.config)
    Fs.ensure_dir(save_path)
    local filename = FileManager.generate_unique_filename()
    self.file_path = save_path .. filename
    vim.api.nvim_buf_set_name(self.buf, self.file_path)
  end

  -- ファイル拡張子に基づいてfiletypeを設定
  -- .mdファイルはmarkdown、.vibingファイルはvibingとする
  local ext = vim.fn.fnamemodify(self.file_path, ":e")
  if ext == "md" then
    vim.bo[self.buf].filetype = "markdown"
  else
    vim.bo[self.buf].filetype = "vibing"
    vim.bo[self.buf].syntax = "markdown"
  end
end

---ウィンドウを作成
function ChatBuffer:_create_window()
  self.win = WindowManager.create_window(self.buf, self.config.window)
  WindowManager.apply_wrap_config(self.win, self.buf)
end

---キーマップを設定
function ChatBuffer:_setup_keymaps()
  local vibing = require("vibing")
  local keymaps = vibing.get_config().keymaps

  local callbacks = {
    send_message = function()
      -- 手動送信は通知チェーンの起点なので、ここで往復カウンタをリセットする。
      -- `ChatBuffer:send_message()` 本体ではなくこのキーマップ側に置くのは、通知の配達自身が
      -- `ProgrammaticSender` 経由で同じ関数を通るため。本体でリセットすると配達のたびに 0 に
      -- 戻り、上限が一切効かなくなる
      require("vibing.application.chat.completion_notifier").on_manual_send(self.buf)
      -- 期限切れキャッシュの確認もここにしか置けない。`ChatBuffer:send_message()` は予約の
      -- 発火・auto_resume・チャット間の配達も通る合流点なので、そちらに置くと無人送信が
      -- `vim.ui.select` の前で止まったまま進まなくなる
      require("vibing.presentation.chat.modules.cache_expiry_prompt").guard(self, function()
        -- 自動 `/compact` は**キャッシュ確認を通ったあと**に挟む。順序は入れ替えられない:
        -- 先に挟むと、ユーザーが確認ダイアログで取りやめた送信のために未送信セクションを
        -- `/compact` に書き換えたまま残すことになる。
        -- 置き場所がここ（`ChatBuffer:send_message()` 本体ではない）なのは上と同じ理由で、
        -- 無人送信に余分なターンを足さないため。差し替わるのは未送信セクションの中身だけ
        pcall(function()
          require("vibing.application.chat.auto_compact").before_manual_send(self)
        end)
        self:send_message()
      end)
    end,
    cancel = function()
      self:cancel_request()
    end,
    update_context_line = function()
      Renderer.updateContextLine(self.buf)
    end,
    close = function()
      self:close()
    end,
  }

  KeymapHandler.setup(self.buf, callbacks, keymaps)
end

---YAMLフロントマターをパース
---@return table<string, string|string[]|number|boolean>
function ChatBuffer:parse_frontmatter()
  return FrontmatterHandler.parse(self.buf)
end

---フロントマターのsession_idを更新
---@param session_id string|nil セッションID（nilの場合はセッションをリセット）
function ChatBuffer:update_session_id(session_id)
  self.session_id = session_id
  -- nilの場合は"~"を設定してYAMLでnullとして扱う
  FrontmatterHandler.update_session_id(self.buf, session_id or "~")

  -- session_id更新時に自動保存（永続化を確実にする）
  if self.buf and vim.api.nvim_buf_is_valid(self.buf) and self.file_path then
    vim.schedule(function()
      if vim.api.nvim_buf_is_valid(self.buf) then
        vim.api.nvim_buf_call(self.buf, function()
          vim.cmd("silent! write")
        end)
      end
    end)
  end
end

---フロントマターのフィールドを更新または追加
---@param key string
---@param value string
---@param update_timestamp? boolean
---@return boolean success
function ChatBuffer:update_frontmatter(key, value, update_timestamp)
  return FrontmatterHandler.update_field(self.buf, key, value, update_timestamp)
end

---フロントマターのリストフィールドを更新（追加/削除）
---@param key string フィールド名
---@param value string|table 追加/削除する要素（`orchestrated` はマップ要素になりうる）
---@param action "add"|"remove" 操作種別
---@return boolean success
function ChatBuffer:update_frontmatter_list(key, value, action)
  return FrontmatterHandler.update_list(self.buf, key, value, action)
end

---フロントマターのリストフィールドを取得
---@param key string フィールド名
---@return (string|table)[] items
function ChatBuffer:get_frontmatter_list(key)
  return FrontmatterHandler.get_list(self.buf, key)
end

---保存されたチャットファイルを読み込む
---@param file_path string
---@return boolean success
function ChatBuffer:load_from_file(file_path)
  local success = FileManager.load_from_file(self.buf, file_path)
  if success then
    self.file_path = file_path
    local frontmatter = self:parse_frontmatter()
    local sid = frontmatter.session_id
    if type(sid) == "string" and sid ~= "" and sid ~= "~" then
      self.session_id = sid
    end
    -- NOTE: Diff display uses patch files in .vibing/patches/<session_id>/
    -- The gd keymap reads patch files directly via PatchFinder and PatchViewer
  end
  return success
end

---セッションIDを取得
---@return string?
function ChatBuffer:get_session_id()
  return self.session_id
end

---会話履歴全体を抽出
---@return {role: string, content: string}[]
function ChatBuffer:extract_conversation()
  return ConversationExtractor.extract_conversation(self.buf)
end

---ユーザーメッセージを抽出（最後の## Userセクション）
---@return string?
function ChatBuffer:extract_user_message()
  return ConversationExtractor.extract_user_message(self.buf)
end

---送信の直前に割り込んでよいメッセージか
---
---スラッシュコマンドはローカル処理で完結し、承認応答は待っているセッションに届かないと
---意味がないため、どちらも遅らせる理由がない。
---
---`<CR>` の手前には割り込みが2つあり（リミット中の予約への切り替えと、期限切れキャッシュの
---確認）、両方が同じ判断をする。同じ条件を2箇所に書くと、3つ目の除外を足したときに片方だけ
---直してスラッシュコマンドや承認応答が黙って飲み込まれる
---@param message string
---@return boolean
function ChatBuffer:can_defer_send(message)
  local commands = require("vibing.application.chat.commands")
  if commands.is_command(message) then
    return false
  end

  local ApprovalParser = require("vibing.presentation.chat.modules.approval_parser")
  if #(self._pending_approvals or {}) > 0 and ApprovalParser.is_approval_response(message) then
    return false
  end

  return true
end

---リミット中の送信を予約に切り替える
---@param message string
---@return boolean scheduled 予約に切り替えたか
function ChatBuffer:_try_schedule_instead_of_send(message)
  local config = require("vibing.config").get()
  local opts = (config.agent and config.agent.scheduled_requests) or {}
  if not opts.enabled then
    return false
  end

  if not self:can_defer_send(message) then
    return false
  end

  local chat_file_path = vim.api.nvim_buf_get_name(self.buf)
  if chat_file_path == "" then
    return false
  end

  -- リミットはバックエンド単位。別のバックエンドで取られた記録でこのチャットを止めると、
  -- リセットまでのあいだ会話そのものができなくなる。
  local Modes = require("vibing.core.constants.modes")
  local LimitState = require("vibing.infrastructure.storage.limit_state")
  local agent = Modes.resolve_agent(self:parse_frontmatter(), config)
  local state = LimitState.get_active(vim.fn.fnamemodify(chat_file_path, ":h"), agent)
  if not state then
    return false
  end

  local AutoResume = require("vibing.application.chat.auto_resume")
  local grace = (config.agent and config.agent.auto_resume_on_limit and config.agent.auto_resume_on_limit.grace_sec)
    or 10
  local fire_at = state.resets_at + grace

  -- 予約本文はバッファにしか無いので、エントリを組む前に保存しておく。保存に失敗したまま
  -- 予約すると、再起動後にfire_scheduled()がディスク上の本文（空）を読み、
  -- "メッセージが空" として黙って予約が失われる。保存できなければ予約せず、
  -- 呼び出し元（send_message）に通常送信させる（fail open）。
  vim.api.nvim_buf_call(self.buf, function()
    vim.cmd("silent! write")
  end)
  if vim.bo[self.buf].modified then
    vim.notify(
      "[vibing] Could not save this chat, so the scheduled message would not survive a restart. Sending normally instead.",
      vim.log.levels.WARN
    )
    return false
  end

  -- quiet=true: this helper's own notification below already names the fire time and the escape
  -- hatch, so schedule()'s generic "scheduled to send in..." notification would just duplicate it.
  local ok, reason =
    AutoResume.schedule_request(chat_file_path, fire_at, { limit_type = state.limit_type, quiet = true })
  if not ok then
    vim.notify("[vibing] Could not schedule this request: " .. tostring(reason), vim.log.levels.WARN)
    return false
  end

  vim.notify(
    string.format(
      "[vibing] Usage limit active - scheduled for %s (in %s). To send now: :VibingCancelResume, then <CR>.",
      os.date("%H:%M", fire_at),
      AutoResume.format_duration(math.max(fire_at - os.time(), 0))
    ),
    vim.log.levels.INFO
  )
  return true
end

---メッセージを送信
---
---戻り値は「このメッセージがリクエストとして扱われたか」。予約に回った場合も、未送信Userとして
---残りリセット後に送られるのでtrueを返す。falseは黙って何もしなかったことを意味し、
---前のターンが残した `:once` エントリを掃除する
---
---`can_use_tool` の `check_session_list` が使うたびに `table.remove` するのが本筋で、これは
---その取りこぼしに対する保険。
---
---**承認への答えを消費するより前に呼ぶ。** 答えは新しい `:once` を積むので、順序が逆だと
---積んだ端から掃除される — `<CR>` を押した瞬間に `allow_once` が効かなくなる形で、しかも
---セッションリストを直接見ないかぎり気づけない
function ChatBuffer:_sweep_spent_once_tools()
  if not self._once_tools then
    return
  end
  for _, once_tool in ipairs(self._once_tools) do
    for i = #self._session_allow, 1, -1 do
      if self._session_allow[i] == once_tool then
        table.remove(self._session_allow, i)
      end
    end
    for i = #self._session_deny, 1, -1 do
      if self._session_deny[i] == once_tool then
        table.remove(self._session_deny, i)
      end
    end
  end
  self._once_tools = nil
end

---拒否の説明行の目印。**文法ではなくリテラルの接頭辞**で、レンダラーが書く
---`⚠️  Tool approval required` と同じ性質のもの。前回の説明を消して書き直すために要る
local APPROVAL_REFUSAL_PREFIX = "⚠️  That answer was not applied."

---答えが適用されなかった理由を、ユーザーが読める場所に置く
---
---**`vim.notify` とバッファの両方に書く。** 通知は消えるので、見逃すとバッファは押す前と
---同じ見た目のまま残り、「`<CR>` を押したのに何も起きなかった」に戻る — それはこの拒否が
---塞ごうとしている状態そのもの。
---
---バッファに書いてよいのは、そこが**我々が描いたブロックの中**だから。期限切れの
---`(expired — ...)` と同じ場所で、承認プロンプトの選択肢行そのものと同じ性質を持つ
---（どれも `extract_user_message` に載る。実測で確認済み）ので、新しい漏れは生まれない。
---
---**前回の説明は、見出しも継続行も消してから書く。** どちらか片方を残すと `<CR>` を押すたびに
---積み上がる。消す範囲は前回のブロックだけで、そこより下の行は番号がずれるが、ずれるのは
---**答えられなかった直後だけ**で、ずらさない代わりに説明が増え続けるほうが読めなくなる
---@param errors string[]
function ChatBuffer:_show_approval_refusal(errors)
  local text = APPROVAL_REFUSAL_PREFIX .. " " .. table.concat(errors, " ")
  -- WARN 以上。情報通知に混ぜると、通知プラグインの設定次第で黙って埋もれる
  vim.notify("[vibing] " .. text, vim.log.levels.WARN)

  if not (self.buf and vim.api.nvim_buf_is_valid(self.buf)) then
    return
  end

  local block = { APPROVAL_REFUSAL_PREFIX }
  for _, reason in ipairs(errors) do
    table.insert(block, "   " .. reason)
  end

  -- **見出し行だけでなく `   理由` の継続行も落とす。** 前の実装は見出しだけを外していたので、
  -- 積み上がりを防ぐために書いたはずの処理が継続行だけを残し、`<CR>` のたびに行が増えていた。
  --
  -- 位置は探す。ユーザーが説明の下に行を打ってから再度 `<CR>` を押すので、前回のブロックが
  -- 末尾にあるとは限らない。書くのは見つけた範囲と末尾の2回だけで、バッファ全体の置き換えは
  -- しない — 編集中の行の extmark と undo を巻き込まないため
  local lines = vim.api.nvim_buf_get_lines(self.buf, 0, -1, false)
  for index, line in ipairs(lines) do
    if vim.startswith(line, APPROVAL_REFUSAL_PREFIX) then
      local last = index
      while lines[last + 1] and vim.startswith(lines[last + 1], "   ") do
        last = last + 1
      end
      vim.api.nvim_buf_set_lines(self.buf, index - 1, last, false, {})
      break
    end
  end

  vim.api.nvim_buf_set_lines(self.buf, -1, -1, false, block)
end

---@class Vibing.AnsweredApproval
---@field outcome "answered_in_place"|"refused"|"retry_as_new_turn"
---@field message string? 再試行として送る本文（`retry_as_new_turn` のときだけ）

---保留中のツール承認への答えを処理する
---
---**`send_message` の冒頭、`cancel_request()` より前に呼ばれる。** 承認がプロセスを殺さずに
---答えられるようになった以上（#778）、答えは「新しいターンの本文」ではなく「いま走っている
---ターンの続き」で、cancel すると答えた瞬間にそのターンが死ぬ。
---
---出口は3つ:
---
---- `answered_in_place` — ブロック中のフックに判定を届けた。ターンはそのまま走り続けるので、
---  送信は起きない
---- `refused` — 曖昧で帰属できなかった。**何も消費していない**ので、ユーザーは行を直して
---  押し直せる。待たせる設計だから拒否が安い
---- `retry_as_new_turn` — 承認は消費したが、そのフックはもう待っていない（今日の kill 経路、
---  または上限に達して deny 済み）。合成した再試行文を新しいターンとして送る
---
---nil は「そもそも承認への答えではない」で、通常の送信がそのまま続く
---@return Vibing.AnsweredApproval?
function ChatBuffer:_answer_pending_approval()
  local pending = self._pending_approvals or {}
  if #pending == 0 then
    return nil
  end

  local message = self:extract_user_message()
  local ApprovalParser = require("vibing.presentation.chat.modules.approval_parser")
  if not message or not ApprovalParser.is_approval_response(message) then
    return nil
  end

  -- 期限切れのものも**答えられる対象に含める**。上限が切ったのは飛んでいたその1回で、
  -- ユーザーが許可を与える機会ではない（`approval_decision.consume` にその理由）。届き方だけが
  -- 変わり、レジストリにもういないので下の `blocked` が nil になって `retry_as_new_turn` に落ちる
  local answerable = {}
  for _, entry in ipairs(pending) do
    table.insert(answerable, entry.request_id)
  end

  -- **曖昧なら拒否する。** 消し忘れた行が別の承認への答えとして通る経路を残さない
  local resolved, errors = ApprovalParser.resolve(message, answerable)
  if #errors > 0 then
    self:_show_approval_refusal(errors)
    return { outcome = "refused" }
  end

  local approval = resolved[1]
  if not approval then
    self:_show_approval_refusal({
      "No pending approval matched that answer. Keep the option line you want, with its "
        .. "`<!-- vibing:req=... -->` marker, and press <CR> again.",
    })
    return { outcome = "refused" }
  end

  -- 判定を届ける前に、フックがまだ待っているかを見ておく。`consume` はプロンプトを消すので、
  -- 後から聞いても「待っていない」と区別がつかない
  local PendingApprovals = require("vibing.infrastructure.rpc.pending_approvals")
  local blocked = PendingApprovals.get(approval.request_id)

  -- 答えが**意味すること**（セッションリストの更新、`:once` の記帳、再試行文）は
  -- `approval_decision.consume` が1箇所で持つ。ここで書き下すのは
  -- `.claude/rules/permissions.md` が禁じるドリフトそのもの
  local ApprovalDecision = require("vibing.application.chat.approval_decision")
  local consumed, err = ApprovalDecision.consume(self, approval)
  if not consumed then
    self:_show_approval_refusal({ string.format("Failed to update permissions: %s", tostring(err)) })
    return { outcome = "refused" }
  end

  if not blocked then
    -- 今日の経路。プロセスは既に死んでいるので、答えは散文として新しいターンで届く
    return { outcome = "retry_as_new_turn", message = consumed.retry_message }
  end

  local Permission = require("vibing.infrastructure.rpc.handlers.permission")
  local ok, released = pcall(Permission.release_answered_approval, blocked, self)
  if not (ok and released) then
    -- フックを解放できないまま黙って戻ると、そのフックは上限まで空回りする。答えは既に
    -- 消費済みなので、再試行文として新しいターンに載せるのが唯一の通る道
    vim.notify(
      string.format(
        "[vibing] Could not answer the waiting %s hook in place (%s); retrying as a new turn.",
        tostring(consumed.tool),
        ok and "it was no longer waiting" or tostring(released)
      ),
      vim.log.levels.WARN
    )
    return { outcome = "retry_as_new_turn", message = consumed.retry_message }
  end

  -- 答えた行はそのまま transcript に残す。あとは走り続けているターンの続きを受け取れる状態に
  -- 戻すことだが、**それが何かは保留が残っているかで変わる**
  -- 訊くのは「まだフックを止めているか」で、プロンプトの行が残っているかではない。残っていても
  -- 誰も待っていないなら入力欄を開いたままにする理由は無く、そこに出力を積むと壊れる
  if self:_has_blocked_approvals() then
    -- まだ答えを待っているものがある。新しい未送信セクションに描き直して入力欄を保つ。
    -- 溜めていた出力は `add_user_section` の中で先に流れるので、順序は時系列のまま
    ConversationExtractor.commit_user_message(self.buf)
    self._approvals_rendered_unsent = false
    self:add_user_section()
  else
    self:_resume_after_approvals()
  end
  return { outcome = "answered_in_place" }
end

---`ProgrammaticSender` はこれを見て呼び出し元に成否を返す
---@return boolean handled
function ChatBuffer:send_message()
  -- 送信処理中はEnter連打による重複送信を無視する
  if self._is_sending then
    return false
  end

  -- 承認の答えを消費する**前**に、前のターンが残した `:once` を落とす。逆順だと、いま積んだ
  -- 許可をその場で掃除してしまう
  self:_sweep_spent_once_tools()

  -- **`cancel_request()` より前。** ブロック中のフックへの答えは新しいターンではなく、
  -- いま走っているターンの続きなので、ここで cancel すると答えた瞬間にそのターンが死ぬ。
  -- 人間の `<CR>` も代理承認も同じこの関数を通る（`.claude/rules/permissions.md` の
  -- 「代理承認は人間の経路をそのまま通る」）
  local answered = self:_answer_pending_approval()
  if answered and answered.outcome ~= "retry_as_new_turn" then
    return answered.outcome == "answered_in_place"
  end

  -- 前のリクエストが実行中ならキャンセル（ゾンビプロセス対策）
  self:cancel_request()
  self._current_turn_id = nil
  self._current_process_id = nil
  self._current_adapter = nil

  self._is_sending = true


  local message = self:extract_user_message()
  if not message then
    vim.notify("[vibing] No message to send", vim.log.levels.WARN)
    self._is_sending = false
    return false
  end

  -- リミット中と分かっているならコミットせずに予約へ回す。commit_user_message を通さないので
  -- `## User <!-- unsent -->` がそのまま残り、それが発火時に送られる本文になる。
  if self:_try_schedule_instead_of_send(message) then
    self._is_sending = false
    return true
  end

  ConversationExtractor.commit_user_message(self.buf)

  local commands = require("vibing.application.chat.commands")
  if commands.is_command(message) then
    local handled, expanded = commands.execute(message, self)
    if handled then
      if expanded then
        message = expanded
      else
        self:add_user_section()
        self._is_sending = false
        return false
      end
    end
  end

  -- Check if message is an approval response
  -- Only process if there's a pending approval request
  -- 承認への答えは `_answer_pending_approval` が `cancel_request()` の手前で処理済み。
  -- ここに来るのは「新しいターンとして再試行する」経路だけで、本文は差し替え済みの再試行文
  if answered and answered.message then
    message = answered.message
  end

  local vibing = require("vibing")
  local adapter = vibing.get_adapter()
  local config = vibing.get_config()
  local SendMessage = require("vibing.application.chat.send_message")

  local callbacks = {
    extract_conversation = function()
      return self:extract_conversation()
    end,
    update_filename_from_message = function(msg)
      return self:update_filename_from_message(msg)
    end,
    start_response = function()
      return self:start_response()
    end,
    parse_frontmatter = function()
      return self:parse_frontmatter()
    end,
    append_chunk = function(chunk, turn_id)
      return self:append_chunk(chunk, turn_id)
    end,
    show_approval_prompts = function()
      return self:show_approval_prompts()
    end,
    get_session_id = function()
      return self:get_session_id()
    end,
    update_session_id = function(session_id)
      return self:update_session_id(session_id)
    end,
    add_user_section = function()
      return self:_finish_turn()
    end,
    get_bufnr = function()
      return self.buf
    end,
    insert_choices = function(questions)
      return self:insert_choices(questions)
    end,
    set_pending_user_text = function(text)
      return self:set_pending_user_text(text)
    end,
    insert_approval_request = function(tool, input, options, hook_request_id, waiting)
      return self:insert_approval_request(tool, input, options, hook_request_id, waiting)
    end,
    get_session_allow = function()
      return self:get_session_allow()
    end,
    get_session_deny = function()
      return self:get_session_deny()
    end,
    clear_turn_id = function()
      self._current_turn_id = nil
      self._current_process_id = nil
      self._current_adapter = nil
    end,
    set_turn_id = function(turn_id)
      self._current_turn_id = turn_id
    end,
    set_process_id = function(process_id)
      self._current_process_id = process_id
    end,
    set_adapter = function(adapter_instance)
      self._current_adapter = adapter_instance
    end,
    get_turn_id = function()
      return self._current_turn_id
    end,
    clear_sending = function()
      self._is_sending = false
    end,
    mark_turn_error = function()
      self:mark_turn_error()
    end,
    get_cwd = function()
      return self:get_cwd()
    end,
    clear_forked_from = function()
      self:update_frontmatter("forked_from", nil)
    end,
  }

  -- 停止理由は「直前のターンがなぜ止まったか」なので、次のターンが実際に走り出すここで捨てる。
  -- `send_message()` の先頭ではない: 本文が空、スラッシュコマンド、承認応答のパース失敗などで
  -- 途中 return する経路がいくつもあり、そこで消すと「まだ承認を待っている」チャットの理由が
  -- 消えて idle に化ける
  self._stop_reason = nil

  -- リクエストを送信（turn_idはコールバックで設定される）
  SendMessage.execute(adapter, callbacks, message, config)

  if self:is_open() then
    Renderer.moveCursorToEnd(self.win, self.buf)
  end

  return true
end

---ターンの締めくくりが書き終わったチャットをディスクに落とす
---
---`vim.schedule` するのは、`add_user_section` が続けて走らせる描画（Context 行の更新）が
---終わってから書くため。名前の無いバッファや書き込めない場所は静かに諦める: 保存できない
---ことでターンの表示まで壊すほうが害が大きい
function ChatBuffer:save_after_turn()
  local buf = self.buf
  vim.schedule(function()
    if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_get_name(buf) ~= "" then
      FileManager.save_buffer(buf)
    end
  end)
end

---アシスタントの応答を追加開始
function ChatBuffer:start_response()
  -- 書いたヘッダーの行番号を覚えておく。ターン完了時に終了時刻を入れるのはこの行で、
  -- 探し直すと本文中の `## Assistant` を拾う（`streaming_handler.stamp_response_end`）
  self._assistant_header_line = StreamingHandler.start_response(self.buf)
end

---バッファリングされたチャンクをフラッシュ
function ChatBuffer:_flush_chunks()
  if #self._chunk_parts == 0 then
    return
  end
  local pending = table.concat(self._chunk_parts)
  self._chunk_parts = {}
  local leftover = StreamingHandler.flush_chunks(self.buf, self.win, pending)
  if leftover ~= "" then
    self._chunk_parts[1] = leftover
  end
end

---ストリーミングチャンクを追加（バッファリング有効）
---キャンセル済みの古いリクエストが遅れて発火したチャンクは、現在アクティブなターンIDと
---一致しない限り無視する
---@param chunk string
---@param turn_id string?
function ChatBuffer:append_chunk(chunk, turn_id)
  if turn_id and self._current_turn_id and turn_id ~= self._current_turn_id then
    return
  end

  -- 片で積んで、流すときに `table.concat` する。承認が立っている間は下の早期returnで
  -- フラッシュが止まるので、`a = a .. chunk` だと最大 `approval_wait_sec`（既定900秒）ぶんの
  -- あいだ、到着するたびに蓄積全体をコピーし直すことになる。kill する設計ではプロセスが
  -- プロンプトの時点で死んでいたので、この形は起こり得なかった
  self._chunk_parts[#self._chunk_parts + 1] = chunk

  if self._chunk_timer then
    vim.fn.timer_stop(self._chunk_timer)
    self._chunk_timer = nil
  end

  -- **承認プロンプトが1件でも立っている間は流さない（#778）。**
  --
  -- append-only のバッファは「入力欄」と「ストリーミング出力」を同時には持てない。プロンプトは
  -- 未送信の `## User` セクションとして末尾にあり、`flush_chunks` も末尾に追記するので、ここで
  -- 流すと**続きの出力がユーザーの入力欄の下に積まれる** — つまりアシスタントの文章が
  -- `extract_user_message` にユーザーの次のメッセージとして拾われる。
  --
  -- 溜まる量の見積もりの出所は `.vibing/probe/concurrency-claude/claude-stream.jsonl`。**1ターン
  -- 分の実測**で、3本の `tool_use` と 3本の `tool_result` のあいだに出たのは `rate_limit_event`
  -- 1行だけ、アシスタントの `text` ブロックはターン通して1つ（全 `tool_result` の後）だった。
  -- その20秒、3本のフックが同時にブロックしている（`hook-concurrency-claude.log`）。
  --
  -- 「claude はブロック中に決して喋らない」への一般化は**未検証**（測ったのは Read 3本の1ターン
  -- だけで、文章とツール呼び出しを交互に出すターンは測っていない）。一般化が外れたときに増える
  -- のは溜まる量だけで、壊れ方は変わらない
  --
  -- 溜めたものは必ず出る。出口は `_flush_chunks` を呼ぶ側全部 — 最後の承認が答えられたとき
  -- （`_answer_pending_approval`）と、ターンが終わったとき（`add_user_section`）。前者が
  -- 抜けても後者が拾うので、期限切れで承認が消えた場合も置き去りにはならない
  if self:_has_blocked_approvals() then
    return
  end

  self._chunk_timer = vim.fn.timer_start(50, function()
    self:_flush_chunks()
    self._chunk_timer = nil
  end)
end

---新しいユーザー入力セクションを追加
function ChatBuffer:add_user_section()
  if self._chunk_timer then
    vim.fn.timer_stop(self._chunk_timer)
    self._chunk_timer = nil
  end
  self:_flush_chunks()

  Renderer.addUserSection(self.buf, self.win, self._pending_choices, self._pending_approvals, self._pending_user_text)
  self._pending_choices = nil
  self._pending_user_text = nil
  -- 「いま末尾の未送信セクションに承認プロンプトが描いてある」。ターンの途中で描けるように
  -- なった以上（#778）、ターンの終わりがもう一度描くと**同じ承認が2つ**出る。どちらの
  -- プロンプトに答えられるのかは見た目では区別がつかない
  self._approvals_rendered_unsent = #(self._pending_approvals or {}) > 0
  -- NOTE: Don't clear _pending_approvals here!
  -- They need to persist until the user answers, and each one is dropped individually by
  -- `approval_decision.consume` when its own answer is spent.
end

---走っているターンの途中で、溜まっている承認プロンプトを描く
---
---**プロセスを殺さない設計で必要になった入口（#778）。** 殺す設計ではプロンプトを描くのは
---ターンの終わり（`_handle_response` → `add_user_section` コールバック）で、そこがアシスタント
---セクションに終了時刻を入れる場所でもあった。待たせる設計ではターンが終わらないので、
---その2つをここで行う:
---
---1. いま開いているアシスタントセクションを閉じる（終了時刻を入れる）。プロンプトは未送信の
---   `## User` セクションとして下に来るので、閉じずに挟むとヘッダの時刻が次のターンまで入らない
---2. `add_user_section` でプロンプトを描く。中で `_flush_chunks` が走るので、**プロンプトより
---   前に届いていた出力はプロンプトの上に出る**。以降の出力は `append_chunk` が溜める
function ChatBuffer:show_approval_prompts()
  StreamingHandler.stamp_response_end(self.buf, self._assistant_header_line)
  self._assistant_header_line = nil
  self:add_user_section()
end

---@return number?
function ChatBuffer:get_buffer()
  return self.buf
end

---最初のメッセージからファイル名を更新
---@param message string
function ChatBuffer:update_filename_from_message(message)
  local new_path = FileManager.update_filename_from_message(self.buf, self.file_path, message)
  if new_path then
    self.file_path = new_path
  end
end

---AskUserQuestion の選択肢を保存
---@param questions table CLIから受け取った質問構造
function ChatBuffer:insert_choices(questions)
  self._pending_choices = questions
  self._stop_reason = "asked_question"
end

---次のユーザーセクションに差し込む本文を保存
---リミットで弾かれたメッセージを予約として書き戻すために使う
---@param text string
function ChatBuffer:set_pending_user_text(text)
  self._pending_user_text = text
end

---ツール承認要求UIを保存
---
---**追記であって置き換えではない。** 1ターンに複数のフックが並列にブロックするので、2件目が
---来たときに1件目を捨てると、そのフックは誰にも答えられないまま上限まで待つことになる。
---`request_id` が同じものが来たら（copilotがフックを切って再実行した場合）、新しい方の内容で
---更新する — 表示を2つに増やしても答えられるのは1つなので
---@param tool string ツール名
---@param input table ツール入力
---@param options table 承認オプション
---@param hook_request_id string? hook-based approval の場合のリクエストID
---@param waiting boolean? このプロンプトが走り続けているターンを止めているか（#778）。
---  レンダラーはこれを見て「このターンの残りの出力は止まっている」と書く。kill する経路では
---  止まっているものが無いので書かない
function ChatBuffer:insert_approval_request(tool, input, options, hook_request_id, waiting)
  self._pending_approvals = self._pending_approvals or {}

  local entry = {
    tool = tool,
    input = input,
    options = options,
    waiting = waiting or nil,
    -- 名前は1つだけ。同じ値を2フィールドに持つと、片方だけ書き換える writer が現れたときに
    -- 帰属が黙って割れる — `request_id` という identity が入ったのは、まさにそれを閉じるため
    request_id = hook_request_id,
  }

  for index, existing in ipairs(self._pending_approvals) do
    if existing.request_id == entry.request_id then
      self._pending_approvals[index] = entry
      self._stop_reason = "waiting_approval"
      return
    end
  end

  table.insert(self._pending_approvals, entry)
  self._stop_reason = "waiting_approval"
end

---この承認は期限切れになった、と印を付ける
---
---**消さない。** ユーザーがいま編集しているバッファから行を取り除くと、その下の全部が
---足元でずれる。印を付けて答えを拒否すれば、ユーザーは「なぜ自分の答えが通らないのか」を
---読める。`.res` は既に deny が書かれていて、フックは解放されている
---@param request_id string
---@return boolean marked 保留していた承認だったか
function ChatBuffer:mark_approval_expired(request_id)
  for _, entry in ipairs(self._pending_approvals or {}) do
    if entry.request_id == request_id then
      entry.expired = true
      return true
    end
  end
  return false
end

---期限切れの説明行の目印。`APPROVAL_REFUSAL_PREFIX` と別なのは、**別の出来事だから**で、
---互いを消してはいけない。拒否は押すたびに書き直される1件だが、期限切れは承認ごとに1回起きる
local APPROVAL_EXPIRED_PREFIX = "⏱️  Tool approval expired."

---承認が待ち時間の上限に達した、という事実をチャットに落とす
---
---**`pending_approvals.expire` の `on_timeout` はここに来る。** `.res` の deny は既に書かれて
---いてフックは解放済みなので、ここに残っているのは「ユーザーに知らせる」ことだけ。それを
---1箇所にまとめてあるのは、印を付けるのと知らせるのが**片方だけ起きてはいけない**から:
---
---- 印だけ付けて黙ると、ユーザーは画面に残った選択肢行を答え、`_answer_pending_approval` の
---  帰属拒否で初めて理由を知る
---- 知らせるだけで印を付けないと、期限切れの承認が `answerable` に残り、答えると誰も待って
---  いないフックに向かって `retry_as_new_turn` が走る
---
---**行は消さずに積む。** 消して書き直すのは拒否（1件しか意味を持たない）の性質で、期限切れは
---承認ごとの独立した出来事。並列に立った3件が別々に切れたら3行残るのが正しい
---@param entry Vibing.PendingApproval 期限に達した保留
---@return boolean marked このチャットが持っていたプロンプトだったか
function ChatBuffer:expire_approval(entry)
  local request_id = entry and entry.request_id
  if not request_id then
    return false
  end

  local marked = self:mark_approval_expired(request_id)

  local waited = require("vibing.infrastructure.hooks.wait_budget").approval_wait_sec()
  local text = string.format(
    "%s %s went unanswered for %d seconds, so vibing.nvim denied that one call.",
    APPROVAL_EXPIRED_PREFIX,
    entry.tool or "A tool",
    waited
  )
  vim.notify("[vibing] " .. text, vim.log.levels.WARN)

  if not (self.buf and vim.api.nvim_buf_is_valid(self.buf)) then
    return marked
  end

  -- 説明を書く**前**に、これが最後のブロックだったなら入力欄を閉じてアシスタントの続きに戻す。
  -- そうすると説明はアシスタントのセクションに入る — 期限切れはユーザーの発言ではないし、
  -- 未送信セクションに書いたままにすると次の `<CR>` でモデルに送り返される。ここを通らないと
  -- **溜めていた出力の出口も無くなる**（`_resume_after_approvals` がその唯一の出口）
  self:_resume_after_approvals()

  local line_count = vim.api.nvim_buf_line_count(self.buf)
  vim.api.nvim_buf_set_lines(self.buf, line_count, line_count, false, {
    text,
    "   The options for it above no longer need an answer.",
  })
  return marked
end

---リストに値をユニークに追加
---@param list table 対象リスト
---@param value any 追加する値
local function add_unique(list, value)
  if not vim.tbl_contains(list, value) then
    table.insert(list, value)
  end
end

---リストから値を削除
---@param list table 対象リスト
---@param value any 削除する値
---@return table 新しいリスト
local function remove_from_list(list, value)
  return vim.tbl_filter(function(item)
    return item ~= value
  end, list)
end

---一時許可/拒否を処理（:once suffix付き）
---@param self Vibing.ChatBuffer
---@param tool string ツール名
---@param target_list table 追加先リスト
local function handle_once_permission(self, tool, target_list)
  local tool_once = tool .. ":once"
  add_unique(target_list, tool_once)
  self._once_tools = self._once_tools or {}
  add_unique(self._once_tools, tool_once)
end

---セッションレベルの許可/拒否を処理
---@param self Vibing.ChatBuffer
---@param tool string ツール名
---@param is_allow boolean 許可かどうか
local function handle_session_permission(self, tool, is_allow)
  if is_allow then
    add_unique(self._session_allow, tool)
    self._session_deny = remove_from_list(self._session_deny, tool)
    self:update_frontmatter_list("permissions_allow", tool, "add")
    self:update_frontmatter_list("permissions_deny", tool, "remove")
  else
    add_unique(self._session_deny, tool)
    self._session_allow = remove_from_list(self._session_allow, tool)
    self:update_frontmatter_list("permissions_deny", tool, "add")
    self:update_frontmatter_list("permissions_allow", tool, "remove")
  end
  self:update_frontmatter_list("permissions_ask", tool, "remove")
end

---セッション許可/拒否を更新（承認レスポンス処理）
---
---ツール名は**引数で受け取る**。以前は `_pending_approval` から読んでいたが、承認が同時に
---複数あり得るようになった以上「いま保留中のもの」は1つに決まらない。どの承認への答えかを
---知っているのは `approval_decision.consume` だけなので、そこが名指しする
---@param approval {action: string, tool: string} パースされた承認データと、その対象ツール
function ChatBuffer:update_session_permissions(approval)
  if not require("vibing.application.chat.approval_decision").is_valid_action(approval.action) then
    vim.notify(
      string.format(
        "[vibing] Invalid approval action: '%s' for tool '%s'",
        tostring(approval.action),
        tostring(approval.tool or "unknown")
      ),
      vim.log.levels.ERROR
    )
    return
  end

  local tool = approval.tool
  if not tool or type(tool) ~= "string" or tool == "" then
    vim.notify("[vibing] Invalid approval: missing or invalid tool name", vim.log.levels.ERROR)
    return
  end

  local action = approval.action
  if action == "allow_once" then
    handle_once_permission(self, tool, self._session_allow)
  elseif action == "deny_once" then
    handle_once_permission(self, tool, self._session_deny)
  elseif action == "allow_for_session" then
    handle_session_permission(self, tool, true)
  elseif action == "deny_for_session" then
    handle_session_permission(self, tool, false)
  end
end

---いま答えを待っているツール承認要求を、表示順に全部
---
---コピーを返す。呼び出し側が必要とするのは「何について止まっているか」を読むことだけで、
---保留を消してよいのは承認が実際に消費されたときだけ。参照を渡すと、その1箇所という保証が
---外から崩せてしまう
---@return {request_id: string?, tool: string, input: table?, options: table?, expired: boolean?}[]
function ChatBuffer:get_pending_approvals()
  return vim.deepcopy(self._pending_approvals or {})
end

---1件だけ取り出す
---
---`request_id` を省略できるのは**保留がちょうど1件のときだけ**。複数あるときに「どれか1つ」を
---返すと、呼び出し側は自分が何に答えているか分からないまま答えることになる
---@param request_id string?
---@return {request_id: string?, tool: string, input: table?, options: table?, expired: boolean?}?
function ChatBuffer:get_pending_approval(request_id)
  local pending = self._pending_approvals or {}
  if not request_id then
    return #pending == 1 and vim.deepcopy(pending[1]) or nil
  end
  for _, entry in ipairs(pending) do
    if entry.request_id == request_id then
      return vim.deepcopy(entry)
    end
  end
  return nil
end

---承認要求を消費済みにする
---
---その承認がリストから消えていることが「答えられた」の唯一の印なので、これを呼んでよいのは
---`approval_decision.consume` だけ。セッションリストの更新と対で起きなければならず、片方だけ
---起きた状態（許可は記録されたのにプロンプトが残る／プロンプトは消えたのに許可が無い）は
---どちらもエラーを出さずに壊れる
---
---**消すのは名指しされた1件だけ。** 全部消すと、同時に出ていた他の承認が答えられないまま
---フックだけが待ち続ける
---@param request_id string?
---@return boolean cleared
function ChatBuffer:clear_pending_approval(request_id)
  local pending = self._pending_approvals or {}
  for index, entry in ipairs(pending) do
    if entry.request_id == request_id or (not request_id and #pending == 1) then
      table.remove(pending, index)
      return true
    end
  end
  return false
end

---セッションレベルの許可リストを取得
---@return table
function ChatBuffer:get_session_allow()
  return vim.deepcopy(self._session_allow)
end

---セッションレベルの拒否リストを取得
---@return table
function ChatBuffer:get_session_deny()
  return vim.deepcopy(self._session_deny)
end

---作業ディレクトリを取得（frontmatterのworking_dirから算出）
---@return string?
function ChatBuffer:get_cwd()
  local frontmatter = self:parse_frontmatter()
  local Git = require("vibing.core.utils.git")
  return Git.resolve_working_dir(frontmatter.working_dir)
end

return ChatBuffer
