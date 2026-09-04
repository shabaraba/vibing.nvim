---@class Vibing.Application.Chat.CacheExpiry
---期限切れのプロンプトキャッシュを書き直す送信かどうかを判定する（確認 UI は
---`presentation/chat/modules/cache_expiry_prompt`）。
---
---判定に要る材料は両方すでにバッファにある: 最終 `## Assistant` ヘッダーの時刻（ターンの
---終わり = 最後にキャッシュが書かれた時刻）と、その `### Tokens` 見出しが持つ context。
---どちらもチャットファイルに書かれるので、Neovim を再起動していても効く。
---
---なぜ両方そろったときだけ聞くのか、閾値の実測値、代わりに何ができるのかは
---`handbook/configuration.md` → "Token Usage"。
local M = {}

local Timestamp = require("vibing.core.utils.timestamp")
local TokenUsage = require("vibing.core.utils.token_usage")

---@class Vibing.CacheExpiry.Decision
---@field elapsed_sec number 最終ターンの終わりからの経過秒
---@field context number 直近ターンのコンテキストサイズ

---最終アシスタントターンの終了時刻と context をバッファから読む
---
---片方でも読めなければ nil。判定は両方そろって初めて意味を持つので、呼び出し側に
---半端な組み合わせを渡さない
---@param buf number
---@return number? epoch
---@return number? context
function M.read_last_turn(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    return nil
  end

  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

  local start, header
  for i = #lines, 1, -1 do
    header = Timestamp.parse_header(lines[i])
    if header and header.kind == "Assistant" then
      start = i
      break
    end
  end
  if not start then
    return nil
  end

  local epoch = Timestamp.to_epoch(header.timestamp)
  if not epoch then
    return nil
  end

  -- context はそのターンの `### Tokens` からしか取らない。バッファ全体から最後の1つを
  -- 拾うと、トークンを報告しないバックエンド（codex/grok）のターンが挟まったときに、
  -- 何ターンも前の数字を「直近のサイズ」として読むことになる
  for i = start + 1, #lines do
    if Timestamp.is_header(lines[i]) then
      return nil
    end
    local context = TokenUsage.parse_context(lines[i])
    if context then
      return epoch, context
    end
  end

  return nil
end

---この送信で確認を出すべきか判定する
---@param chat_buffer Vibing.ChatBuffer
---@return Vibing.CacheExpiry.Decision?
function M.evaluate(chat_buffer)
  local config = require("vibing.config").get()
  local opts = (config.agent and config.agent.token_usage) or {}
  if opts.enabled == false then
    return nil
  end

  -- 既定値は token_usage 側から借りる（config.lua と同じ理由）。手組みの config テーブルで
  -- 片方だけ既定に落ちると、閾値の組み合わせが設定した覚えのないものになる
  local ttl = tonumber(opts.cache_ttl_sec) or TokenUsage.DEFAULT_CACHE_TTL_SEC
  local warn_context = tonumber(opts.warn_context) or TokenUsage.DEFAULT_WARN_CONTEXT
  -- `warn_context = 0` は `### Tokens` 側で「内訳だけ出して警告は止める」を意味する。
  -- 閾値を共有している以上、その意思表示はこちらにも効かせる
  if ttl <= 0 or warn_context <= 0 then
    return nil
  end

  -- 応答中の `<CR>` は `send_message` が黙って無視する。確認を出してから何も起きないほうが
  -- 分かりにくいので、ここで降りる
  if chat_buffer._is_sending then
    return nil
  end

  -- 閾値の判定を先に済ませる。ほとんどの `<CR>` は1時間以内の返信なので、ここで降りる分には
  -- 本文の抽出（バッファ全体の読み直し）も除外判定も要らない
  local epoch, context = M.read_last_turn(chat_buffer.buf)
  if not epoch then
    return nil
  end
  local elapsed = os.time() - epoch
  if elapsed < ttl or context < warn_context then
    return nil
  end

  local message = chat_buffer:extract_user_message()
  if not message or not chat_buffer:can_defer_send(message) then
    return nil
  end

  return { elapsed_sec = elapsed, context = context }
end

return M
