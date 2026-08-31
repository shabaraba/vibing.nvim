---@class Vibing.Application.Chat.InheritedFrontmatter
---親チャットから新しいチャットへ引き継ぐfrontmatterの共通部分。
---forkとsubagent chatはここが完全に一致し、違うのは出自を示す1フィールド
---（`forked_from` / `subagent_id`）だけなので、引き継ぎ範囲は片方に足してもう片方に
---足し忘れないようここに一本化する。
---
---`orchestrated` / `orchestrated_by` は**意図的に**含めない。ここは明示的なホワイトリスト
---なので既に落ちているが、足してはいけないことを記録しておく: forkもsubagent chatも自分では
---誰とも関係を結んでいないのに、親の関係を自分のものとして主張することになる
---（`SubagentMarker.strip` がforkでマーカーを剥がすのと同じ理由）
local M = {}

local Modes = require("vibing.core.constants.modes")

---@param source table 引き継ぎ元のfrontmatter
---@param config table
---@return table
function M.from_source(source, config)
  return {
    ["vibing.nvim"] = true,
    session_id = source.session_id or "~",
    created_at = os.date("%Y-%m-%dT%H:%M:%S"),
    working_dir = source.working_dir,
    agent = source.agent or (config.adapter or "claude"),
    -- 不正なmodeは引き継がない（コピーすると誤りが増殖するだけなのでデフォルトに戻す）。
    -- 黙って戻す: send_message側が送信時に警告を出すので、引き継ぎのたびに同じ誤字を
    -- 二重に通知しても意味がない
    mode = Modes.coerce_agent_mode(source.mode) or (config.agent and config.agent.default_mode or "code"),
    model = source.model or (config.agent and config.agent.default_model or "sonnet"),
    -- effortは設定がなければ渡さない（CLI側の既定に委ねる）ので、fallbackもnilで正しい
    effort = source.effort or (config.agent and config.agent.default_effort),
    permission_mode = source.permission_mode or (config.permissions and config.permissions.mode or "acceptEdits"),
    permissions_allow = source.permissions_allow or (config.permissions and config.permissions.allow or {}),
    permissions_deny = source.permissions_deny or (config.permissions and config.permissions.deny or {}),
    -- askも権限の一部。落とすと「毎回確認する」と決めたツールが確認なしで動くほうに倒れる
    permissions_ask = source.permissions_ask or (config.permissions and config.permissions.ask or nil),
    language = source.language,
  }
end

return M
