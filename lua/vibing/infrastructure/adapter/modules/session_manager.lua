---@class Vibing.SessionManager
---Manages session ID storage and retrieval for conversation continuity.
---Uses handle_id as key to track multiple concurrent sessions.
local M = {}

---新しいセッション管理インスタンスを作成
---@return table セッション管理インスタンス
function M.new()
  return {
    _sessions = {}
  }
end

---セッションIDを保存
---@param self table セッション管理インスタンス
---@param handle_id string ハンドルID
---@param session_id string セッションID
function M.store(self, handle_id, session_id)
  if handle_id then
    self._sessions[handle_id] = session_id
  end
end

---セッションIDを取得
---@param self table セッション管理インスタンス
---@param handle_id string? ハンドルID（nilの場合はデフォルトセッションIDを返す）
---@return string? セッションID（未実行の場合はnil）
function M.get(self, handle_id)
  if handle_id then
    return self._sessions[handle_id]
  else
    -- handle_id が指定されていない場合は、デフォルトキーから取得
    return self._sessions["__default__"]
  end
end

---セッションIDを設定（外部から明示的に設定）
---保存されたチャットファイルを開く際に、フロントマターのsession_idを設定
---次回のstream()呼び出し時に--session引数として渡される
---@param self table セッション管理インスタンス
---@param session_id string? セッションID（nilの場合は新規セッション）
---@param handle_id string? ハンドルID（nilの場合は最新のセッションIDとして保存）
function M.set(self, session_id, handle_id)
  if handle_id then
    self._sessions[handle_id] = session_id
  else
    -- handle_id が指定されていない場合は、後方互換性のため特別なキーに保存
    self._sessions["__default__"] = session_id
  end
end

---セッションIDをクリーンアップ
---get()でセッションIDを取得した後に呼び出してメモリを解放
---@param self table セッション管理インスタンス
---@param handle_id string クリーンアップするハンドルID
function M.cleanup(self, handle_id)
  if handle_id then
    self._sessions[handle_id] = nil
  end
end

---すべての完了済みセッションをクリーンアップ
---_handlesに存在しない_sessionsエントリを削除
---@param self table セッション管理インスタンス
---@param handles table<string, table> アクティブなハンドルマップ
function M.cleanup_stale(self, handles)
  for handle_id in pairs(self._sessions) do
    -- __default__ キーと実行中のハンドルは保持
    if handle_id ~= "__default__" and not handles[handle_id] then
      self._sessions[handle_id] = nil
    end
  end
end

return M
