---@class Vibing.SessionManager
---Manages session ID storage and retrieval for conversation continuity.
---
---Keyed by **process id**, not by turn: a CLI session is something a process holds open, and the
---next turn learns which session to `--resume` by reading it back off the process that just ran
---(`send_message._handle_response`). A turn-keyed map would answer nil for a resident process's
---second turn (#774).
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
---@param process_id string プロセスID
---@param session_id string セッションID
function M.store(self, process_id, session_id)
  if process_id then
    self._sessions[process_id] = session_id
  end
end

---セッションIDを取得
---@param self table セッション管理インスタンス
---@param process_id string? プロセスID（nilの場合はデフォルトセッションIDを返す）
---@return string? セッションID（未実行の場合はnil）
function M.get(self, process_id)
  if process_id then
    return self._sessions[process_id]
  else
    -- process_id が指定されていない場合は、デフォルトキーから取得
    return self._sessions["__default__"]
  end
end

---セッションIDを設定（外部から明示的に設定）
---保存されたチャットファイルを開く際に、フロントマターのsession_idを設定
---次回のstream()呼び出し時に--session引数として渡される
---@param self table セッション管理インスタンス
---@param session_id string? セッションID（nilの場合は新規セッション）
---@param process_id string? プロセスID（nilの場合は最新のセッションIDとして保存）
function M.set(self, session_id, process_id)
  if process_id then
    self._sessions[process_id] = session_id
  else
    -- process_id が指定されていない場合は、後方互換性のため特別なキーに保存
    self._sessions["__default__"] = session_id
  end
end

---セッションIDをクリーンアップ
---get()でセッションIDを取得した後に呼び出してメモリを解放
---@param self table セッション管理インスタンス
---@param process_id string クリーンアップするプロセスID
function M.cleanup(self, process_id)
  if process_id then
    self._sessions[process_id] = nil
  end
end

---すべての完了済みセッションをクリーンアップ
---_processesに存在しない_sessionsエントリを削除
---@param self table セッション管理インスタンス
---@param processes table<string, table> 生きているプロセスのマップ
function M.cleanup_stale(self, processes)
  for process_id in pairs(self._sessions) do
    -- __default__ キーと実行中のプロセスは保持
    if process_id ~= "__default__" and not processes[process_id] then
      self._sessions[process_id] = nil
    end
  end
end

return M
