---@class Vibing.DiffConfig
---diff表示設定
---ファイル変更のdiff表示に使用するツールを制御
---@field tool "git"|"auto" 使用するdiffツール（現在は同義。リクエストごとにワーキングツリーの
---  gitツリースナップショットを取り、その差分をパッチとして保存する。`gd` はそのパッチを、
---  無ければ通常の git diff を表示する）

---@class Vibing.GradientConfig
---グラデーションアニメーション設定
---AI応答中に行番号をグラデーションアニメーションで視覚的にフィードバック
---@field enabled boolean グラデーションアニメーション有効化（trueで応答中に行番号がアニメーション）
---@field colors string[] グラデーション色の配列（2色指定: {開始色, 終了色}、例: {"#cc3300", "#fffe00"}）
---@field interval number アニメーション更新間隔（ミリ秒、デフォルト: 100）

---@class Vibing.ToolMarkersConfig
---ツールマーカー設定
---チャット出力でツール実行時に表示する視覚的マーカーをカスタマイズ
---ツール名 → マーカー文字列のフラットな対応表。マーカーの解決にはツール名しか渡らないため、
---コマンド内容による出し分け（Bashの`^npm`だけ別マーカー等）は行えない
---@field Task? string Taskツールのマーカー（デフォルト: "▶"）
---@field default? string 個別指定のないツール用マーカー（デフォルト: "⏺"）
---@field [string]? string ツール名をキーとしたマーカー文字列

---@class Vibing.UiConfig
---UI設定
---全UIコンポーネント（Chat、Output）に適用される表示設定
---@field wrap "nvim"|"on"|"off" 行の折り返し設定（"nvim": Neovimデフォルト、"on": wrap+linebreak有効、"off": wrap無効）
---@field gradient Vibing.GradientConfig グラデーションアニメーション設定（応答中の視覚的フィードバック）
---@field tool_result_display "none"|"compact"|"full" ツール実行結果の表示モード（"none": 非表示、"compact": 数行のみ、"full": 全文表示）
---@field tool_markers? Vibing.ToolMarkersConfig ツールマーカー設定（ツール実行時の視覚的マーカー）

---@class Vibing.Config
---vibing.nvimプラグインの設定オブジェクト
---アダプター選択、チャットウィンドウ、キーマップ、ツール権限を統合管理
---@field adapter? "claude"|"codex"|"copilot"|"grok" バックエンドアダプター選択（デフォルト: "claude"）
---@field agent Vibing.AgentConfig エージェント設定（モード、モデル）
---@field chat Vibing.ChatConfig チャットウィンドウ設定（位置、サイズ、自動コンテキスト、保存先）
---@field ui Vibing.UiConfig UI設定（wrap等）
---@field keymaps Vibing.KeymapConfig キーマップ設定（送信、キャンセル、コンテキスト追加）
---@field diff Vibing.DiffConfig diff表示設定（使用ツール）
---@field permissions Vibing.PermissionsConfig ツール権限設定（許可/拒否リスト）
---@field grok Vibing.GrokConfig Grok Build CLI設定（バイナリパス）
---@field mcp Vibing.McpConfig MCP統合設定（RPCポート、自動起動）
---@field language? string|Vibing.LanguageConfig AI応答のデフォルト言語（"ja", "en"等、またはLanguageConfig）
---@field daily_summary? Vibing.DailySummaryConfig Daily Summary機能設定
---@field dap? Vibing.DapConfig nvim-dap連携設定

---@class Vibing.PermissionRule
---粒度の細かい権限制御ルール
---ツール入力パラメータに基づいて許可/拒否を制御
---@field tools string[] 対象ツール名のリスト（例: {"Read", "Write"}）
---@field paths string[]? ファイルパスのglobパターンリスト（例: {"src/**", "tests/**"}）
---@field commands string[]? Bashコマンド名のリスト（例: {"npm", "yarn"}）
---@field patterns string[]? Bashコマンドパターン（**Lua pattern**であって正規表現ではない）のリスト（例: {"^rm%s+%-rf", "^sudo%f[%W]"}）。`-`は量指定子なのでリテラルは`%-`とエスケープすること
---@field domains string[]? 許可/拒否するドメインリスト（例: {"github.com", "*.example.com"}）
---@field action "allow"|"deny" ルールのアクション（"allow": 許可、"deny": 拒否）
---@field message string? 拒否時のメッセージ（actionが"deny"の場合に表示）

---@class Vibing.PermissionsConfig
---ツール権限設定
---CLIに対してClaudeが使用可能なツールを制御（Read, Edit, Write, Bash等）
---allowで許可、denyで拒否、askで確認を要求し、セキュリティと機能のバランスを調整
---@field mode "default"|"acceptEdits"|"bypassPermissions"|"plan"|"dontAsk"|"auto" 権限モード
---@field allow string[] 許可するツールリスト（例: {"Read", "Edit", "Write"}）
---@field deny string[] 拒否するツールリスト（例: {"Bash"}、危険なツールを明示的に禁止）
---@field ask string[] 確認が必要なツールリスト（例: {"Bash"}、使用前に承認を要求）
---@field rules Vibing.PermissionRule[]? 粒度の細かい権限制御ルール（オプション）
---@field default_deny_rules boolean? 破壊的Bashコマンド（`rm -rf /`、`sudo`、`dd`、`chmod -R 777`、main/masterへのforce push等）の同梱denyルールを有効にするか（デフォルト: true）。`core/constants/destructive_commands.lua`を参照

---@class Vibing.AutoResumeOnLimitConfig
---使用量リミット自動継続設定
---使用量リミットで応答が弾かれたとき、リセット時刻を待って自動で継続リクエストを送る
---@field enabled boolean リミット時に自動で継続リクエストを送るか（デフォルト: false、無人でトークンを消費するため）
---@field max_retries number 1回のリミットヒットにつき許可する自動再送の回数（再送がまたリミットに当たった時点で打ち切り）
---@field prompt string 再送する継続プロンプト（セッションはresumeされるので文脈の再説明は不要）。予約リクエスト（Vibing.ScheduledRequestsConfig）が途中まで進んだターンを再開するときも同じ文言を使う
---@field fallback_delay_sec number リセット時刻が取得できなかった場合の待ち時間（秒）
---@field grace_sec number リセット時刻からの上乗せ秒数（境界ぴったりで再送して弾かれるのを防ぐ）

---@class Vibing.ScheduledRequestsConfig
---予約リクエスト設定
---使用量リミット中に送信しようとしたリクエストを、リセット後に送る予約に切り替える
---途中まで進んだターンが弾かれた場合だけは本文ではなく継続文言（auto_resume_on_limit.prompt）を予約する
---@field enabled boolean リミット中のリクエストを予約に切り替えるか（デフォルト: true、リミット中のリクエストはどのみち失敗するため）
---@field max_retries number 予約したリクエストがまた弾かれたときに許可する再予約の回数

---@class Vibing.ChatNotificationsConfig
---チャット間の完了通知設定
---別チャットに送ったリクエストの完了を、送信元のチャットに通知する
---通知は送信元の新しいターンとして届くため、無人でトークンを消費する
---@field enabled boolean 普通に止まっただけのチャットについての watchdog 通知を配達するか
---  （デフォルト: false、無人でトークンを消費するため）。質問・承認待ち・エラーで止まった
---  チャットの通知はこの設定に依らず配られる（自力では抜けられず、自分で報告もできないため）
---@field max_round_trips number 2チャット間（無向ペア）で連続して配達してよい通知の数。手動送信（<CR>）でリセットされる
---@field max_wakes number 手動送信を挟まずに配達してよい通知の総数。ツリー全体の暴走に対する最終防壁

---@class Vibing.OrchestrationConfig
---チャット網の走らせ方に関する設定
---@field max_concurrent number 同時に応答中にできるチャットの本数。0で無制限（デフォルト: 0）。
---  見るのは機械が始める送信（`nvim_chat_send_message`とキューの配達）だけで、人間の<CR>は止めない
---@field delegated_approval boolean? 別のチャットが`nvim_chat_answer_approval`でツール承認
---  プロンプトに代理で答えられるようにするか（デフォルト: false）。承認ゲートはユーザーのために
---  あるので、エージェントが別のエージェントのゲートを外せる状態は権限モデルそのものの変更であり、
---  既定にはしない

---@class Vibing.AgentConfig
---エージェント設定
---Claudeのモード（code/plan/explore）とモデル（sonnet/opus/haiku/fable）を指定
---@field default_mode "code"|"plan"|"explore" 新規チャットのfrontmatterに記録される`mode`の既定値（意味は core/constants/modes.lua の M.AGENT_MODES 参照）
---@field default_model "sonnet"|"opus"|"haiku"|"fable" デフォルトモデル（"sonnet": バランス、"opus": 高性能、"haiku": 高速、"fable": Claude Fable）
---@field utility_model "sonnet"|"opus"|"haiku"|"fable" タイトル生成・要約等の軽量ユーティリティ呼び出し専用モデル（デフォルト: "sonnet"）
---@field default_effort ("low"|"medium"|"high"|"xhigh"|"max")? 推論量の既定値（未指定ならCLIの既定に任せる）
---@field utility_effort ("low"|"medium"|"high"|"xhigh"|"max")? タイトル生成・要約等の軽量呼び出しの推論量（デフォルト: "low"）
---@field setting_sources string[]? Claude CLIの`--setting-sources`に渡す設定読み込み元リスト（例: {"project", "local"}、デフォルト: {"user", "project", "local"}）
---@field subagent Vibing.SubagentConfig? subagent（Task/Agentツール）の出力表示設定
---@field auto_resume_on_limit Vibing.AutoResumeOnLimitConfig 使用量リミット自動継続設定
---@field scheduled_requests Vibing.ScheduledRequestsConfig 予約リクエスト設定
---@field chat_notifications Vibing.ChatNotificationsConfig チャット間の完了通知設定
---@field orchestration Vibing.OrchestrationConfig チャット網の並列度設定
---@field codex_provider_notice Vibing.CodexProviderNoticeConfig codex軽量呼び出しのプロバイダ警告設定
---@field token_usage Vibing.TokenUsageConfig ターンごとのトークン内訳表示とコンテキスト肥大警告の設定
---@field plugins Vibing.PluginsConfig? `--plugin-dir`で読み込むClaude Codeプラグインの設定

---@class Vibing.TokenUsageConfig
---ターンごとのトークン内訳（コンテキストサイズ・リクエスト数・キャッシュ読取/作成）をチャットに
---出し、コンテキストが育ったら警告する。
---
---codex_provider_notice と同じ理由で既定で有効: トークンを一切使わず、無効だと当の問題
---（チャットが育っていることに気づけない）がそのまま残る通知だから。
---@field enabled boolean? falseで表示と警告を止める（デフォルト: true）
---@field warn_context number? この値を超えている間、各ターンの内訳行の直下に警告を書く（デフォルト: 150000）

---@class Vibing.PluginsConfig
---セッション限りで読み込むClaude Codeプラグインのディレクトリ設定（claudeバックエンドのみ）
---`--plugin-dir`はユーザーのグローバル状態に何も書かずにプラグインを読む。vibing.nvim自身の
---`claude-plugin/`もこれで渡すため、MCPサーバーとバンドルskillは常に「いま動いているcheckout」の
---ものになる（worktreeを含む）。
---@field self boolean? falseでvibing.nvim自身のclaude-plugin/を渡さなくなる。nvim_*のMCPツールと
---  バンドルskillが全て消えるのでデバッグ用の逃げ道であり、通常は触らない（デフォルト: true）
---@field project_dir string|false? プロジェクトルートからの相対パス。この直下の各ディレクトリを
---  プラグインとして渡す。falseで無効化（デフォルト: ".vibing/plugins"）
---@field extra string[]? 任意の追加パス。絶対パス、`~`始まり、またはリクエストのcwd相対（デフォルト: {}）

---@class Vibing.CodexProviderNoticeConfig
---codexの軽量呼び出し（タイトル生成・要約等）が設定済みプロバイダから外れることを警告するか
---警告のために`codex doctor --json`を1セッション1回だけ起動する。他の多くのトグルと違い既定で
---有効なのは、これがトークンを使う機能ではなく「黙って宛先が変わる」ことを防ぐ安全側の通知で、
---既定で無効ではそもそも気づけないため。probeのプロセス起動自体を避けたい場合に無効化する。
---@field enabled boolean? falseでプロバイダ警告とそのprobeを完全に止める（デフォルト: true）

---@class Vibing.SubagentConfig
---subagentが喋った内容をチャットに出すかどうかの設定
---既定では subagent の中身は隠され、ツール結果だけが見える（従来の挙動）
---@field enabled boolean? trueでCLIに`--forward-subagent-text`を渡し、subagentの本文をチャットに表示する（デフォルト: false）
---@field show_prefix boolean? 各行に`[subagent_type]`のラベルを付けるか（デフォルト: false）

---@class Vibing.GrokConfig
---Grok Build CLI設定
---`adapter = "grok"`（またはfrontmatterの`agent: grok`）のときだけ参照される。
---@field executable string|"auto" grokバイナリのパス（"auto": PATHから自動検出、文字列: 明示的なパス指定）

---@class Vibing.McpConfig
---MCP統合設定
---Neovim RPC ServerとMCPサーバーの連携を制御
---@field enabled boolean MCP統合の有効化（trueでRPCサーバーを起動）
---@field rpc_port number RPCサーバーのポート番号（デフォルト: 9876）

---@class Vibing.ChatConfig
---チャット機能設定
---ウィンドウ位置・サイズ、自動コンテキスト、保存先、コンテキスト挿入位置を管理
---@field window Vibing.WindowConfig ウィンドウ表示設定（位置、幅、枠線）
---@field auto_context boolean 自動コンテキスト有効化（trueで開いているバッファを自動的にコンテキストに含める）
---@field save_location_type "project"|"user"|"custom" 保存先タイプ（"project": プロジェクト内、"user": ユーザーディレクトリ、"custom": カスタムパス）
---@field save_dir string カスタム保存先ディレクトリ（save_location_type="custom"時に使用）

---@class Vibing.WindowConfig
---チャットウィンドウ表示設定
---位置、幅、高さ、枠線スタイルを制御
---@field position "right"|"left"|"top"|"bottom"|"back"|"current"|"float" ウィンドウ位置（"right": 右分割、"left": 左分割、"top": 上分割、"bottom": 下分割、"back": バッファのみ作成、"current": 現在のウィンドウ、"float": フローティング）
---@field width number ウィンドウ幅（0-1の小数で画面比率、1以上で絶対カラム数。right/left/floatで使用）。境界に注意: `1`は100%ではなく1カラム
---@field height number? ウィンドウ高さ（0-1の小数で画面比率、1以上で絶対行数。top/bottom/floatで使用。`1`は100%ではなく1行）。未指定時の既定値は位置により異なり、分割は0.4、floatは0.8
---@field border string 枠線スタイル（"rounded", "single", "double", "none"等）。floatのみ有効で、値は`nvim_open_win`にそのまま渡される（vibing.nvim側の検証はしない）

---@class Vibing.KeymapConfig
---キーマップ設定
---チャットバッファ内での操作キーを定義
---@field send string メッセージ送信キー（デフォルト: "<CR>"）
---@field cancel string 実行キャンセルキー（デフォルト: "<C-c>"）
---@field add_context string コンテキスト追加キー（デフォルト: "<C-a>"）
---@field open_diff string ファイルパス上でdiff表示キー（デフォルト: "gd"）
---@field open_file string ファイルパス上でファイルを開くキー（デフォルト: "gf"）
---@field open_url string カーソル行のURLをブラウザで開くキー（デフォルト: "gx"）

---@class Vibing.LanguageConfig
---言語設定（詳細）
---アクションごとに異なる言語を指定可能
---@field default? string デフォルト言語（"ja", "en", "zh", "ko", "fr", "de", "es"等）
---@field chat? string chatアクションでの言語（指定されていない場合はdefaultを使用）

---@alias Vibing.FileFinderStrategy "auto"|"fd"|"find"|"locate"|"ripgrep"

---@class Vibing.DapConfig
---nvim-dap連携設定
---デバッガが停止したときに、その状態をエージェントに解析させる
---nvim-dapは任意依存。未インストールなら各機能は「入っていない」と報告して何もしない
---@field enabled boolean? 停止イベントの購読を有効にするか（デフォルト: false）
---@field auto_analyze_on_error boolean? 例外で止まったとき自動で解析を投げるか（デフォルト: true）
---@field auto_analyze_on_breakpoint boolean? ブレークポイントで止まったとき自動で投げるか（デフォルト: false）

---@class Vibing.DailySummaryConfig
---Daily Summary機能設定
---当日のチャットファイルから日報を生成する機能の設定
---@field save_dir? string サマリー保存先ディレクトリ（nilの場合はチャット保存先の/daily/サブディレクトリ）
---@field search_dirs string[] VibingDailySummaryAllで検索するディレクトリのリスト（空配列の場合はデフォルトディレクトリを検索、要素が存在する場合はそのリストのみを再帰検索）
---@field file_finder_strategy? Vibing.FileFinderStrategy ファイル検索戦略（"auto": 最適なツールを自動選択、"fd": fd使用、"find": find使用、"locate": locate/plocate使用、"ripgrep": rg使用）

local notify = require("vibing.core.utils.notify")

local tools_const = require("vibing.core.constants.tools")
local language_utils = require("vibing.core.utils.language")
local token_usage = require("vibing.core.utils.token_usage")

local M = {}

---Validate tool_markers configuration
---Markers are a flat "tool name -> marker string" table.
---@param markers table Tool markers config to validate
---@return table Validated markers config
local function validate_tool_markers(markers)
  local validated = {}

  for key, marker in pairs(markers) do
    if type(marker) == "string" then
      if marker == "" then
        notify.warn(string.format("ui.tool_markers.%s is empty string - will use default", key))
      else
        validated[key] = marker
      end
    elseif type(marker) == "table" then
      -- Legacy `{ default = "x", patterns = {...} }`. `patterns` was documented but never
      -- implemented — resolution only ever receives a tool name, never the command string — so
      -- the whole form is dropped loudly rather than silently ignored. See issue #502.
      -- Name `patterns` only when the user actually wrote it: mentioning a feature they never
      -- used reads like a warning about something else.
      local detail = marker.patterns ~= nil and "; patterns never had any effect and is dropped"
        or ""
      notify.warn(
        string.format("ui.tool_markers.%s: give the marker string directly%s", key, detail)
      )
      if type(marker.default) == "string" and marker.default ~= "" then
        validated[key] = marker.default
      end
    else
      notify.warn(
        string.format("Invalid ui.tool_markers.%s: must be a string, got %s", key, type(marker))
      )
    end
  end

  return validated
end

---@type Vibing.Config
M.defaults = {
  adapter = "claude",
  agent = {
    default_mode = "code",
    default_model = "sonnet",
    -- sonnet, not haiku: the utility calls are all summarisation over a noisy chat transcript,
    -- and haiku measurably picks the wrong subject (it titles a chat after the last step or the
    -- commands that ran). The inputs are a few thousand tokens and the calls are on-demand, so
    -- the extra cost is small. Set it back to "haiku" if you want the cheapest possible.
    utility_model = "sonnet",
    -- default_effort is deliberately nil: without it vibing.nvim passes no --effort and the CLI
    -- applies its own default, which moves as Anthropic tunes it. Set it to pin a level.
    default_effort = nil,
    utility_effort = "low",
    setting_sources = { "user", "project", "local" },
    subagent = {
      enabled = false,
      show_prefix = false,
    },
    -- 使用量リミットで応答が弾かれたとき、リセット時刻を待って自動で継続リクエストを送る。
    -- 無人でトークンを消費するため既定は無効。
    auto_resume_on_limit = {
      enabled = false,
      -- 1回のリミットヒットにつき許可する自動再送の回数。
      -- 再送がまたリミットに当たった時点で打ち切られる。
      max_retries = 1,
      -- 再送する継続プロンプト。セッションはresumeされるので文脈の再説明は不要。
      -- scheduled_requests 側も、途中まで進んだターンを再開するときはこの文言を使う。
      prompt = "Continue from where you left off.",
      -- リセット時刻が取得できなかった場合の待ち時間（秒）。
      fallback_delay_sec = 300,
      -- リセット時刻からの上乗せ秒数。境界ぴったりで再送して弾かれるのを防ぐ。
      grace_sec = 10,
    },
    -- 使用量リミット中に送信しようとしたリクエストを、リセット後に送る予約に切り替える。
    -- リミット中のリクエストはどのみち失敗するため既定で有効。
    -- :VibingSchedule による明示的な予約はこのフラグに関係なく常に動く。
    --
    -- 予約する本文は、弾かれたターンが何も出力せず終わったなら元の本文、途中まで進んでいたなら
    -- auto_resume_on_limit.prompt。進んでいた分はセッションのtranscriptに残っているので、
    -- 同じ依頼を送り直すと済んだ作業をやり直させることになる。
    scheduled_requests = {
      enabled = true,
      -- 予約したリクエストがまた弾かれたときに許可する再予約の回数。
      -- これがループの唯一の歯止めなので 0 未満にはしない。
      max_retries = 3,
    },
    -- 別チャットに送ったリクエストの完了を、送信元のチャットに通知する。
    -- 通知は送信元の新しいターンとして届くため無人でトークンを消費する。既定は無効で、
    -- これは subagent / auto_resume_on_limit / dap と同じ基準（トークンを使う機能は既定で切る）。
    -- scheduled_requests や codex_provider_notice が既定で有効なのはトークンを使わないからで、
    -- こちらには当てはまらない。
    --
    -- 無効でも止まるのは watchdog の配達だけ。`orchestrated` / `orchestrated_by` の記録も、
    -- ワーカーに「誰に報告すればいいか」を伝えるシステムプロンプトの1行も、`queue_if_busy` の
    -- 配達も、質問・承認待ち・エラーで止まったチャットの通知も、設定に依らず動く。
    -- 無効化が消すのは「普通に止まっただけのチャットについて自発的に声をかける」ぶんだけで、
    -- ワーカーが自分から報告する経路と、自力では抜けられない止まり方の検知は残る。
    chat_notifications = {
      enabled = false,
      -- 通知が連鎖して自走するのを止める上限は2段。A→B→A→B の往復は正当なユースケース
      -- （Bの質問にAが答える）なので、循環検出ではなく回数で止める。どちらも<CR>による
      -- 手動送信で0に戻る。
      --
      -- 上限を「起こされた回数」のグローバルカウンタから (A,B) ペア単位に変えたのは、
      -- 止めたいのが A⇄B の無限往復であって扇状の受信数ではないため。子N人からの完了通知を
      -- 受けるだけで上限に当たるのは、正当なオーケストレータを止めていた（#644）。
      max_round_trips = 8,
      -- 配達が多くのペアに散ってペア上限に当たらない形（扇、長い循環）への最終防壁なので、
      -- 通常の運用では届かない大きさにしてある。
      max_wakes = 50,
    },
    orchestration = {
      -- 同時に応答中にできるチャットの本数。0は無制限で、既定で無効なのは、有効にすると
      -- 既存のオーケストレーションの配達順が黙って変わるため。扇の幅がレート制限に
      -- 当たるようになったら締めるつまみ（application/chat/concurrency.lua）。
      --
      -- 上限に当たった送信は捨てられずキューに残り、枠が空いた完了イベントで配り直される。
      -- 人間の<CR>はこの上限を見ない。
      max_concurrent = 0,
      -- ワーカーが `ask` 対象のツールに当たると、そのチャットは `waiting_approval` で止まり、
      -- 自力では抜けられない。既定ではそれを外せるのはユーザーだけで、オーケストレーターは
      -- 「どのチャットが何で止まっているか」を言うところまでしかできない。
      --
      -- true にすると、オーケストレーターは `nvim_chat_answer_approval` で4択
      -- （allow_once / deny_once / allow_for_session / deny_for_session）に代理で答えられる。
      -- 扇の全員が同じ承認で止まる運用ではこれが唯一の現実解だが、買っているのは
      -- 「エージェントが別のエージェントの承認ゲートを外せる」状態そのものなので、
      -- opt-in にしてある。答えは配達セクション（`## Request <!-- ... from ... -->`）として
      -- ワーカーのtranscriptに残るので、誰が許可したかは後から読める。
      delegated_approval = false,
    },
    -- codexの軽量呼び出しは --ignore-user-config で走るので、ユーザーの model_provider が落ちて
    -- 既定のOpenAIエンドポイントに向く。それを1セッション1回だけ警告する。
    --
    -- auto_resume_on_limit や dap と違って既定で有効なのは、これがトークンを使う機能ではなく、
    -- 黙って宛先が変わることを防ぐ通知だから。既定で無効なら、気づけないという当の問題が残る。
    -- 代償は `codex doctor --json` の起動が1回入ることで、doctorには単一チェックだけ走らせる
    -- フラグが無いためプロバイダへの到達性通信も付いてくる。それを避けたい場合はfalseにする。
    codex_provider_notice = {
      enabled = true,
    },
    -- ターンのコストは「返答の長さ」ではなく「リクエスト数 × コンテキストサイズ」で決まる。
    -- ツール1回ごとにAPIリクエストが1本増え、そのたびに会話全体を読み直すため。
    --
    -- 自動コンパクトはこれを救わない。発火はコンテキスト上限の手前（このリポジトリのログで
    -- 実測して約93万トークン）で、そこまで登る間の全リクエストは育ったサイズのまま課金される。
    -- つまりコンパクトは溢れないための救命装置であって、コスト対策ではない。
    --
    -- 既定値は実測から取った。プレフィックスキャッシュを引き当てられず同じ内容を作成価格で
    -- 書き直す率が、30k未満で0%、30〜80kで1.1%、80〜150kで4.8%、150k超で6.9%。この境目から
    -- 先は読取量と書き直しの確率が両方効いてくる。
    --
    -- 値そのものは token_usage 側から借りる。`config` が未設定のとき（テストや手組みの
    -- config テーブル）に使われるフォールバックが同じモジュールにあり、2箇所に同じ数字を
    -- 置くと片方だけ動かして既定値が食い違う
    token_usage = {
      enabled = true,
      warn_context = token_usage.DEFAULT_WARN_CONTEXT,
    },
    -- `--plugin-dir` で読み込むプラグイン。self → project_dir → extra の順で渡す。
    --
    -- 順序は意味を持つ。同名プラグインを複数渡すと**先に渡した方が勝つ**（claude 2.1.231で実測）。
    -- self を先頭に置いているので、プロジェクト側のプラグインが名前を合わせて vibing.nvim 自身を
    -- 乗っ取ることはできない。
    --
    -- project_dir を既定で読むのは利便性を取った判断で、リスクは受容している。プラグインは
    -- mcpServers を宣言できるため、クローンしたリポジトリに仕込まれた `.vibing/plugins/` は
    -- 最初のチャット送信時に任意のプロセスを起動しうる。信用できないリポジトリでは false にする。
    plugins = {
      self = true,
      project_dir = ".vibing/plugins",
      extra = {},
    },
  },
  chat = {
    window = {
      position = "current",
      width = 0.4,
      -- heightは意図的に未設定。既定値がpositionごとに違うのでwindow_manager側で解決する
      -- （handbook/configuration.md の chat.window.height 参照）
      border = "rounded",
    },
    auto_context = true,
    save_location_type = "project",
    save_dir = vim.fn.stdpath("data") .. "/vibing/chats",
  },
  ui = {
    wrap = "on",
    gradient = {
      enabled = true,
      colors = { "#cc3300", "#fffe00" },
      interval = 100,
    },
    tool_result_display = "compact",
    tool_markers = {
      Task = "▶",
      default = "⏺",
    },
  },
  keymaps = {
    send = "<CR>",
    cancel = "<C-c>",
    add_context = "<C-a>",
    open_diff = "gd",
    open_file = "gf",
    open_url = "gx",
  },
  diff = {
    tool = "auto",
  },
  permissions = {
    mode = "acceptEdits",
    allow = vim.deepcopy(tools_const.DEFAULT_ALLOWED_TOOLS),
    deny = { "Bash" },
    ask = {},
    rules = {},
    default_deny_rules = true,
  },
  grok = {
    executable = "auto",
  },
  mcp = {
    enabled = true,
    rpc_port = 9876,
  },
  language = nil,
  daily_summary = {
    save_dir = nil,
    search_dirs = {},
    file_finder_strategy = "auto",
  },
  -- nvim-dapで止まったときの自動解析。既定は無効で、有効にしても既定はエラー時のみ。
  -- ブレークポイントは意図して置くものなので、止まるたびに無人でトークンを使われると邪魔になる
  dap = {
    enabled = false,
    auto_analyze_on_error = true,
    auto_analyze_on_breakpoint = false,
  },
}

---@type Vibing.Config?
M.options = nil

---vibing.nvimプラグインの設定を初期化
---ユーザー設定とデフォルト設定をマージし、ツール権限の妥当性を検証
---permissionsで指定されたツール名が有効かチェックし、無効な場合は警告を出力
---@param opts? Vibing.Config ユーザー設定オブジェクト（nilの場合はデフォルト設定のみ使用）
function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", {}, M.defaults, opts or {})

  -- Auto-add "Skill" to permissions.allow if not already present and not in deny/ask lists
  if M.options.permissions and M.options.permissions.allow then
    local has_skill = false
    local is_denied = false
    local is_ask = false

    -- Check if Skill is already in allow list
    for _, tool in ipairs(M.options.permissions.allow) do
      if tool == "Skill" then
        has_skill = true
        break
      end
    end

    -- Check if Skill is in deny list
    if M.options.permissions.deny then
      for _, tool in ipairs(M.options.permissions.deny) do
        if tool == "Skill" then
          is_denied = true
          break
        end
      end
    end

    -- Check if Skill is in ask list (user wants confirmation before use)
    if M.options.permissions.ask then
      for _, tool in ipairs(M.options.permissions.ask) do
        if tool == "Skill" then
          is_ask = true
          break
        end
      end
    end

    -- Add Skill if not present and not denied and not in ask list
    if not has_skill and not is_denied and not is_ask then
      table.insert(M.options.permissions.allow, "Skill")
    end
  end

  if M.options.permissions then
    -- Validate permission mode
    local valid_modes = {
      default = true,
      acceptEdits = true,
      bypassPermissions = true,
      plan = true,
      dontAsk = true,
      auto = true,
    }
    local mode = M.options.permissions.mode
    if mode and not valid_modes[mode] then
      notify.warn(string.format(
        "Invalid permissions.mode '%s'. Valid values: default, acceptEdits, bypassPermissions, plan, dontAsk, auto",
        mode
      ))
    end

    -- Helper: Validate tool name or Bash pattern
    local function is_valid_tool(tool_str)
      -- Check for Bash pattern: Bash(command:*)
      if tool_str:match("^Bash%([^:]+:%*%)$") then
        return true
      end
      -- Check for MCP tool: mcp__server__tool
      if tool_str:match("^mcp__") then
        return true
      end
      -- Check built-in tools
      return tools_const.VALID_TOOLS_MAP[tool_str] ~= nil
    end

    -- Validate tool names
    for _, tool in ipairs(M.options.permissions.allow or {}) do
      if not is_valid_tool(tool) then
        notify.warn(string.format("Unknown tool '%s' in permissions.allow", tool))
      end
    end
    for _, tool in ipairs(M.options.permissions.deny or {}) do
      if not is_valid_tool(tool) then
        notify.warn(string.format("Unknown tool '%s' in permissions.deny", tool))
      end
    end
    for _, tool in ipairs(M.options.permissions.ask or {}) do
      if not is_valid_tool(tool) then
        notify.warn(string.format("Unknown tool '%s' in permissions.ask", tool))
      end
    end
  end

  local function validate_enum(value, valid_values, field_name, default)
    if value and not valid_values[value] then
      -- tbl_keysの順序は不定なので、警告文が実行ごとに変わらないようソートする
      local keys = vim.tbl_keys(valid_values)
      table.sort(keys)
      local valid_list = table.concat(keys, ", ")
      notify.warn(string.format(
        "Invalid %s value '%s'. Valid values: %s. Falling back to '%s'.",
        field_name, value, valid_list, default
      ))
      return default
    end
    return value
  end

  if M.options.ui then
    M.options.ui.wrap = validate_enum(
      M.options.ui.wrap,
      { nvim = true, on = true, off = true },
      "ui.wrap",
      "on"
    )
    M.options.ui.tool_result_display = validate_enum(
      M.options.ui.tool_result_display,
      { none = true, compact = true, full = true },
      "ui.tool_result_display",
      "compact"
    )
  end

  if M.options.diff then
    -- mote統合は削除された。`"mote"` を弾いてデフォルトに戻すと、明示的にmoteを選んで
    -- いたユーザーが「なぜか設定が無視される」状態になるので、名指しで案内して "git" に倒す。
    --
    -- 正規化した値は `M.options` にしか書かないので、ユーザーの `opts` テーブルには古い設定が
    -- 残ったまま。setup()を2回以上呼ぶ構成（設定の再読み込み等）だと、そのたびに同じ警告が
    -- 出ることになる。削除された設定の案内はどれも `notify.warn_once` に乗せて1回に抑える。
    if M.options.diff.tool == "mote" then
      notify.warn_once(
        "config.diff.tool",
        "diff.tool = \"mote\" is no longer supported and is being treated as \"git\". "
          .. "mote integration was removed: diffs now come from a git tree snapshot taken per "
          .. "request, which also catches Bash-driven file changes. Remove the setting."
      )
      M.options.diff.tool = "git"
    end
    if M.options.diff.mote ~= nil then
      notify.warn_once("config.diff.mote", "diff.mote is no longer used and can be removed from your setup() call.")
      M.options.diff.mote = nil
    end
    M.options.diff.tool = validate_enum(
      M.options.diff.tool,
      { git = true, auto = true },
      "diff.tool",
      "auto"
    )
  end

  if M.options.agent then
    -- `max_hops`（起こされた回数のグローバルカウンタ）は (A,B) ペアの往復カウンタと
    -- 全体予算に置き換わった。黙って無視すると「上限を下げたはずなのに効いていない」に
    -- 気づけないので、`diff.tool = "mote"` と同じく名指しで案内する
    -- 型を見るのは、`chat_notifications = true` のような壊れた設定でも `setup()` を落とさない
    -- ため。`vim.tbl_deep_extend("force", ...)` は非テーブルで既定値ごと置き換えるので、素朴に
    -- 索引すると boolean を index して落ちる。この経路は今回追加したものなので、少なくとも
    -- 変更前より壊れやすくはしない
    local notifications = M.options.agent.chat_notifications
    if type(notifications) == "table" and notifications.max_hops ~= nil then
      notify.warn_once(
        "config.agent.chat_notifications.max_hops",
        "agent.chat_notifications.max_hops is no longer used and is being ignored. "
          .. "The chain is now bounded per chat pair by max_round_trips (default 8), with "
          .. "max_wakes (default 50) as a whole-tree budget. Remove the setting."
      )
      notifications.max_hops = nil
    end

    local modes = require("vibing.core.constants.modes")
    local valid_agent_modes = {}
    for _, mode in ipairs(modes.AGENT_MODES) do
      valid_agent_modes[mode] = true
    end
    M.options.agent.default_mode =
      validate_enum(M.options.agent.default_mode, valid_agent_modes, "agent.default_mode", "code")
  end

  if M.options.ui and M.options.ui.gradient then
    local gradient = M.options.ui.gradient

    if gradient.colors then
      if type(gradient.colors) ~= "table" or #gradient.colors ~= 2 then
        notify.warn("Invalid ui.gradient.colors: must be an array of exactly 2 hex color strings.")
        M.options.ui.gradient.colors = { "#cc3300", "#fffe00" }
      else
        for i, color in ipairs(gradient.colors) do
          if type(color) ~= "string" or not color:match("^#%x%x%x%x%x%x$") then
            notify.warn(string.format(
              "Invalid color format at ui.gradient.colors[%d]: '%s'. Expected hex format like '#ff0000'.",
              i, tostring(color)
            ))
          end
        end
      end
    end

    if gradient.interval and (type(gradient.interval) ~= "number" or gradient.interval <= 0) then
      notify.warn("Invalid ui.gradient.interval: must be a positive number.")
      M.options.ui.gradient.interval = 100
    end
  end

  if M.options.ui and M.options.ui.tool_markers then
    M.options.ui.tool_markers = validate_tool_markers(M.options.ui.tool_markers)
  end

  if M.options.language then
    local function validate_lang_code(code, field_name)
      if code and code ~= "" and code ~= "en" and not language_utils.language_names[code] then
        local supported = table.concat(vim.tbl_keys(language_utils.language_names), ", ")
        notify.warn(string.format("Unknown language code '%s' in %s. Supported: %s", code, field_name, supported))
      end
    end

    if type(M.options.language) == "string" then
      validate_lang_code(M.options.language, "language")
    elseif type(M.options.language) == "table" then
      validate_lang_code(M.options.language.default, "language.default")
      validate_lang_code(M.options.language.chat, "language.chat")
    end
  end

  -- Validate daily_summary.search_dirs
  if M.options.daily_summary and M.options.daily_summary.search_dirs then
    local search_dirs = M.options.daily_summary.search_dirs
    if type(search_dirs) ~= "table" then
      notify.warn(string.format(
        "Invalid daily_summary.search_dirs: expected table, got %s. Resetting to default.",
        type(search_dirs)
      ))
      M.options.daily_summary.search_dirs = {}
    else
      local valid_dirs = {}
      for i, dir in ipairs(search_dirs) do
        if type(dir) ~= "string" or dir == "" then
          notify.warn(string.format(
            "Invalid daily_summary.search_dirs[%d]: expected non-empty string, got %s. Skipping.",
            i, type(dir)
          ))
        else
          table.insert(valid_dirs, dir)
        end
      end
      M.options.daily_summary.search_dirs = valid_dirs
    end
  end

  -- grok_command_builder tells the user to "set config.grok.executable" when the binary is
  -- missing, so a bad value here has to be validated -- otherwise the advice leads to a setting
  -- nothing checks. A missing binary is NOT reset to "auto": `adapter = "grok"` with a wrong path
  -- should say so, not quietly fall back to whatever `grok` happens to be on PATH.
  if M.options.grok and M.options.grok.executable then
    local executable = M.options.grok.executable
    if type(executable) ~= "string" or executable == "" then
      notify.warn(
        string.format(
          "Invalid grok.executable value '%s'. Must be 'auto' or a path to the grok binary. Resetting to 'auto'.",
          tostring(executable)
        )
      )
      M.options.grok.executable = "auto"
    elseif executable ~= "auto" and vim.fn.executable(executable) == 0 then
      notify.warn(
        string.format("Grok CLI not found at '%s'. Grok chats will fail until this is corrected.", executable)
      )
    end
  end
end

---現在の設定を取得
---setup()で初期化された設定オブジェクトを返す
---setup()が未実行の場合はデフォルト設定を返す
---@return Vibing.Config 現在の設定オブジェクト
function M.get()
  return M.options or M.defaults
end

return M
