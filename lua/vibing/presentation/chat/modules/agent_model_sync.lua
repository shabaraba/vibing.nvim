--- `agent:` を変えたとき、`model:` をそのバックエンドの既定へ追従させる。
---
--- frontmatterは利用者が直接編集する前提なので、プログラムからの更新（`]v` の巡回）だけを
--- 拾うのでは足りない。バッファの変更を見て、直前の agent と変わったときだけ書き換える。
---
--- 既定は `ai_config.resolve` と同じ順（`ai.agents.<id>.chat_model` → バックエンド定義）。
--- 追従先が無ければ `model:` 行を消す — 前のバックエンドの値を持ち越すと、送信時に黙って
--- 捨てられるか、CLI に拒否されるかのどちらかになるだけなので。
local M = {}

local Agents = require("vibing.core.constants.agents")
local FrontmatterHandler = require("vibing.presentation.chat.modules.frontmatter_handler")

---バッファ変数に置くのは、バッファが消えたときに片付けが要らないため
local AGENT = "vibing_agent_model_agent"
local PENDING = "vibing_agent_model_pending"

---追従を実行する。`]v` の巡回とテストはこれを直接呼ぶ（API の書き換えでは autocmd が
---発火しないため）
---@param buf integer
function M.sync(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  vim.b[buf][PENDING] = nil

  local agent = FrontmatterHandler.parse(buf).agent
  local previous = vim.b[buf][AGENT]
  vim.b[buf][AGENT] = agent
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
  vim.b[buf][AGENT] = FrontmatterHandler.parse(buf).agent
  local group = vim.api.nvim_create_augroup("vibing_agent_model_" .. buf, { clear = true })
  vim.api.nvim_create_autocmd({ "TextChanged", "InsertLeave" }, {
    group = group,
    buffer = buf,
    callback = function()
      if vim.b[buf][PENDING] then
        return
      end
      vim.b[buf][PENDING] = true
      -- 入力中に書かない。InsertLeave で拾うので、値の途中で model が動くこともない
      vim.schedule(function()
        M.sync(buf)
      end)
    end,
    desc = "Keep model in step with a changed agent",
  })
end

return M
