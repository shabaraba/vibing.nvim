--- `:VibingChatSearch` の評価用クエリと正解。コーパスは `tests/fixtures/chat_search/corpus/`。
---
--- `expected` は返さなければ取りこぼしになるチャット、`acceptable` は返しても誤りにしない
--- チャット、`distractors` は語が一致するが関係のないチャットで、誤検出の内訳を読むために挙げる。
--- コーパスの語彙はクエリの語と一致しないように書いてあり、言い換えずに grep すると落ちる。

---@param id string
---@return string
local function chat(id)
  local files = {
    refresh_token = "chat-20260512-101503-00001a2f3b4c5d6e-7a1c.md",
    refresh_two_tabs = "chat-20260519-153012-00001b7e8a9c0d1f-2b3d.md",
    login_layout = "chat-20260520-091544-00001c3d4e5f6a7b-3c4e.md",
    task_list_n_plus_one = "chat-20260603-140210-00001d9a8b7c6d5e-4d5f.md",
    vite_build_slow = "chat-20260604-110033-00001e2f3a4b5c6d-5e6a.md",
    i18n = "chat-20260610-163020-00001f4a5b6c7d8e-6f7b.md",
    due_date_utc = "chat-20260615-102255-0000204b6c7d8e9f-7a8c.md",
    playwright_flaky = "chat-20260618-131800-0000215c7d8e9fa0-8b9d.md",
    jest_to_vitest = "chat-20260620-094512-0000226d8e9fa0b1-9cae.md",
    docker_image_size = "chat-20260625-170133-0000237e9fa0b1c2-adbf.md",
    actions_cache = "chat-20260627-112040-000024af0b1c2d3e-bec0.md",
    docker_m1 = "chat-20260701-083015-000025b0c1d2e3f4-cfd1.md",
    soft_delete = "chat-20260708-142233-000026c1d2e3f405-d0e2.md",
    deleted_in_search = "chat-20260712-100510-000027d2e3f40516-e1f3.md",
    delete_dialog = "chat-20260714-153344-000028e3f4051627-f2a4.md",
    ses_bounce = "chat-20260718-091022-000029f405162738-03b5.md",
    slack_webhook = "chat-20260721-134455-00002a0516273849-14c6.md",
    readme = "chat-20260723-170000-00002b162738495a-25d7.md",
    renovate = "chat-20260728-102030-00002c2738495a6b-36e8.md",
    service_split = "chat-20260801-141516-00002d38495a6b7c-47f9.md",
    login_rate_limit = "chat-20260804-093030-00002e495a6b7c8d-580a.md",
    csv_bom = "chat-20260807-112233-00002f5a6b7c8d9e-691b.md",
    kanban_a11y = "chat-20260810-150505-0000306b7c8d9eaf-7a2c.md",
    kanban_order = "chat-20260813-101010-0000317c8d9eafb0-8b3d.md",
    kanban_realtime = "chat-20260816-133000-0000328d9eafb0c1-9c4e.md",
    feature_flags = "chat-20260819-090909-0000339eafb0c1d2-ad5f.md",
    sentry_setup = "chat-20260822-160000-000034afb0c1d2e3-be60.md",
    sentry_release = "chat-20260826-111111-000035b0c1d2e3f4-cf71.md",
    password_reset = "chat-20260829-140000-000036c1d2e3f405-d082.md",
    dark_mode = "chat-20260902-100000-000037d2e3f40516-e193.md",
  }
  return assert(files[id], "unknown chat id: " .. id)
end

---@param ids string[]?
---@return string[]
local function chats(ids)
  return vim.tbl_map(chat, ids or {})
end

---@param case {id: string, query: string, expected: string[]?, acceptable: string[]?, distractors: string[]?}
---@return Vibing.ChatSearchEval.Case
local function case(case)
  return {
    id = case.id,
    query = case.query,
    expected = chats(case.expected),
    acceptable = chats(case.acceptable),
    distractors = chats(case.distractors),
  }
end

---@type Vibing.ChatSearchEval.Case[]
return {
  case({
    id = "refresh_token/two_chats",
    query = "リフレッシュトークンの実装について話したチャット",
    expected = { "refresh_token", "refresh_two_tabs" },
    distractors = { "renovate", "password_reset", "login_layout" },
  }),
  case({
    id = "slow_list/named_only_by_assistant",
    query = "タスク一覧が遅かった件、どう直したっけ",
    expected = { "task_list_n_plus_one" },
    distractors = { "vite_build_slow" },
  }),
  case({
    id = "due_date/rephrased",
    query = "期限日が1日ずれるバグ",
    expected = { "due_date_utc" },
    distractors = { "i18n" },
  }),
  case({
    id = "flaky/e2e_not_in_text",
    query = "E2Eテストがたまに落ちる問題",
    expected = { "playwright_flaky" },
    distractors = { "jest_to_vitest" },
  }),
  case({
    id = "docker/image_size",
    query = "Dockerイメージを小さくした話",
    expected = { "docker_image_size" },
    distractors = { "docker_m1", "readme" },
  }),
  case({
    id = "soft_delete/follow_up",
    query = "論理削除",
    expected = { "soft_delete", "deleted_in_search" },
    distractors = { "delete_dialog" },
  }),
  case({
    id = "csv/mojibake",
    query = "CSVをExcelで開くと文字化けする",
    expected = { "csv_bom" },
  }),
  case({
    id = "sentry/unreadable_stack",
    query = "Sentryでスタックトレースが読めない問題",
    expected = { "sentry_release" },
    acceptable = { "sentry_setup" },
    distractors = { "renovate" },
  }),
  case({
    id = "none/graphql",
    query = "GraphQLのスキーマ設計について相談したチャット",
    distractors = { "task_list_n_plus_one" },
  }),
  case({
    id = "slack/english_query",
    query = "where did we set up Slack notifications for task assignment",
    expected = { "slack_webhook" },
    distractors = { "readme" },
  }),
  case({
    id = "kanban/order",
    query = "カンバンの並び順を保存する方法",
    expected = { "kanban_order" },
    acceptable = { "kanban_realtime" },
    distractors = { "kanban_a11y" },
  }),
  case({
    id = "login/brute_force",
    query = "ブルートフォース対策",
    expected = { "login_rate_limit" },
    distractors = { "password_reset", "login_layout" },
  }),
  case({
    id = "email/delivery",
    query = "メールがちゃんと届いたか確認する仕組みを作ったチャット",
    expected = { "ses_bounce" },
    distractors = { "password_reset" },
  }),
  case({
    id = "none/kubernetes",
    query = "Kubernetesへのデプロイ設定",
    distractors = { "docker_image_size", "docker_m1" },
  }),
  case({
    id = "docker/m1_english",
    query = "the chat about docker build failing on my M1 Mac",
    expected = { "docker_m1" },
    distractors = { "docker_image_size" },
  }),
  case({
    id = "test/jest_migration",
    query = "Jestからの移行",
    expected = { "jest_to_vitest" },
    distractors = { "renovate", "playwright_flaky" },
  }),
}
