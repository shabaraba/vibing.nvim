--- `agent:` を変えたとき、`model:` をそのバックエンドの既定へ追従させる。
---
--- frontmatterは利用者が直接編集する前提なので、プログラムからの更新（`]v` の巡回や
--- `nvim_chat_create` の agent 指定）だけを拾うのでは足りない。バッファの変更を見て、
--- 直前の agent と変わったときだけ書き換える。
---
--- 既定は `ai_config.resolve` と同じ順（`ai.agents.<id>.chat_model` → バックエンド定義）。
--- 追従先が無ければ `model:` 行を消す — 前のバックエンドの値を持ち越すと、送信時に黙って
--- 捨てられるか、CLI に拒否されるかのどちらかになるだけなので。
local M = {}

local Agents = require("vibing.core.constants.agents")
local FrontmatterHandler = require("vibing.presentation.chat.modules.frontmatter_handler")

---@type table<integer, string?> このバッファが直前に持っていた agent
local last_agent = {}
---@type table<integer, boolean> 適用を予約済みか（TextChanged は連続で来る）
local pending = {}

---予約した追従を実行する。テストから直接呼べるよう公開している
---@param buf integer
function M.sync(buf)
  pending[buf] = nil
  if not vim.api.nvim_buf_is_valid(buf) then
    last_agent[buf] = nil
    return
  end

  local agent = FrontmatterHandler.parse(buf).agent
  local previous = last_agent[buf]
  last_agent[buf] = agent
  if agent == previous or not Agents.is_valid(agent) then
    return
  end

  local model = require("vibing.core.utils.ai_config").resolve(require("vibing.config").get(), agent).model
  -- `updated_at` は動かさない。値を手で書き換えたときと同じ結果になるべきなので
  FrontmatterHandler.update_field(buf, "model", model, false)
end

---バッファの frontmatter を監視する。開いた時点の agent を基準にするので、既存チャットを
---開いただけで model が書き換わることはない
---@param buf integer
function M.watch(buf)
  last_agent[buf] = FrontmatterHandler.parse(buf).agent
  local group = vim.api.nvim_create_augroup("vibing_agent_model_" .. buf, { clear = true })
  vim.api.nvim_create_autocmd({ "TextChanged", "InsertLeave" }, {
    group = group,
    buffer = buf,
    callback = function()
      if pending[buf] then
        return
      end
      pending[buf] = true
      -- 入力中に書かない。InsertLeave で拾うので、値の途中で model が動くこともない
      vim.schedule(function()
        M.sync(buf)
      end)
    end,
    desc = "Keep model in step with a changed agent",
  })
  vim.api.nvim_create_autocmd("BufUnload", {
    group = group,
    buffer = buf,
    callback = function()
      last_agent[buf] = nil
      pending[buf] = nil
    end,
    desc = "Forget the agent this buffer last had",
  })
end

return M
