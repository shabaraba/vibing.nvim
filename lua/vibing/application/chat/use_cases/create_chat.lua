---@class Vibing.Application.CreateChatUseCase
---プログラムからの新規チャット作成（MCPツール `nvim_chat_create` の実体）
---
---`:VibingChat` と違うのは `working_dir` を指定できる点だけで、セッション生成そのものは
---`use_case.create_new` に委譲する。fork/subagent_chat と同じく、ここはPresentation層に
---依存しない: 呼び出し元が返ってきたsessionをviewに渡す
local M = {}

local Git = require("vibing.core.utils.git")

---作成時に呼び出し元が決められるfrontmatterのキー。どれもチャット単位の既存のキーで、
---ここで新しい意味を持たせるものは無い — 書いた後は人間が編集した値と区別されない
local OVERRIDABLE_KEYS = { "agent", "model", "effort", "profile" }

---@param value any
---@return boolean
local function is_plain_string(value)
  -- frontmatterの1行として書ける値だけ。改行を含む値は次のキーを偽装できる
  return type(value) == "string" and value ~= "" and #value <= 200 and not value:find("[%c]")
end

---`nvim_chat_create`の`agent`/`model`/`effort`/`profile`を、`worker_defaults`と合わせて
---新しいチャットのfrontmatterに載せる値へ解決する。
---
---不正な値は**黙って落とさずエラーにする**（`delegated_scope`の寛容さとは逆）。モデル指定が
---落ちたワーカーは既定のモデル — 多くの場合オーケストレーター自身と同じ高価なもの — で黙って
---走り、この引数が存在する理由そのものを失うため。チャットを作る**前**に呼ぶこと。
---@param requested table<string, any> 呼び出しの引数
---@param defaults Vibing.WorkerDefaults|nil `agent.orchestration.worker_defaults`
---@return table<string, string>|nil overrides
---@return string|nil err
function M.resolve_frontmatter(requested, defaults)
  local Modes = require("vibing.core.constants.modes")
  local Profiles = require("vibing.core.constants.profiles")
  requested = requested or {}
  defaults = type(defaults) == "table" and defaults or {}

  local overrides = {}
  for _, key in ipairs(OVERRIDABLE_KEYS) do
    local value = requested[key]
    local origin = key
    if value == nil or value == vim.NIL then
      value = defaults[key]
      origin = "agent.orchestration.worker_defaults." .. key
    end
    if value ~= nil and value ~= vim.NIL then
      if not is_plain_string(value) then
        return nil, string.format("%s must be a non-empty single-line string", origin)
      end
      if key == "agent" and not Modes.is_valid_agent(value) then
        return nil,
          string.format(
            "Unknown %s '%s' (expected one of: %s)",
            origin,
            value,
            table.concat(require("vibing.core.constants.agents").ORDER, ", ")
          )
      end
      if key == "effort" and not Modes.is_valid_effort(value) then
        return nil,
          string.format("Unknown %s '%s' (expected one of: %s)", origin, value, table.concat(Modes.EFFORT_VALUES, ", "))
      end
      if key == "profile" and not Profiles.is_valid(value) then
        return nil,
          string.format("Unknown %s '%s' (expected one of: %s)", origin, value, table.concat(Profiles.VALUES, ", "))
      end
      overrides[key] = value
    end
  end
  return overrides, nil
end

---新しいチャットセッションを作成する
---@param opts? {working_dir?: string, frontmatter?: table<string, string>} working_dirはgitルートからの相対パス。
---  frontmatterは`resolve_frontmatter`が解決済みの値
---@return Vibing.ChatSession
---@throws working_dirがgit管理外、または存在しないディレクトリを指している場合
function M.execute(opts)
  opts = opts or {}
  local working_dir = opts.working_dir

  if not working_dir or working_dir == "" then
    return require("vibing.application.chat.use_case").create_new({ frontmatter = opts.frontmatter })
  end

  -- 存在しないディレクトリを受け入れると、チャットは作れてしまうのに最初のリクエストで
  -- 初めて失敗する。しかもワーカーのバッファはユーザーが見ていないので、ここで弾く
  local absolute = Git.resolve_working_dir(working_dir)
  if not absolute then
    error("Cannot resolve working_dir '" .. working_dir .. "': not inside a git repository")
  end
  if vim.fn.isdirectory(absolute) ~= 1 then
    error("working_dir does not exist: " .. working_dir .. " (resolved to " .. absolute .. ")")
  end

  return require("vibing.application.chat.use_case").create_new({
    working_dir = working_dir,
    frontmatter = opts.frontmatter,
  })
end

return M
