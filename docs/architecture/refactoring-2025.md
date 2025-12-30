# Architecture Refactoring (2025-12-30)

## 概要

vibing.nvimのアーキテクチャをClean Architectureの原則に従ってリファクタリングしました。

## 主な変更点

### 1. Presentation層の導入

**Before**: コマンドがApplication層を直接呼び出し、Application層がView（ChatBuffer）に依存

**After**: Presentation層のControllerを介してApplication層を呼び出し、依存方向を修正

#### 新規ファイル

- `lua/vibing/presentation/chat/controller.lua` - チャット機能のController
- `lua/vibing/presentation/chat/view.lua` - チャット機能のViewファサード
- `lua/vibing/presentation/inline/controller.lua` - インライン機能のController
- `lua/vibing/presentation/context/controller.lua` - コンテキスト管理のController

### 2. Domain層の導入

**Before**: Application層が直接ChatBuffer（View）を操作

**After**: ドメインモデル（ChatSession）を導入してビジネスロジックとUIを分離

#### 新規ファイル

- `lua/vibing/domain/chat/session.lua` - チャットセッションのドメインモデル

### 3. Application層の改善

**Before**:

```lua
-- ❌ Application層がPresentation層に依存
local ChatBuffer = require("vibing.presentation.chat.buffer")
M.chat_buffer = ChatBuffer:new()
```

**After**:

```lua
-- ✅ Application層はドメインモデルのみを扱う
local ChatSession = require("vibing.domain.chat.session")
M._current_session = ChatSession:new()
```

### 4. コマンド登録の改善

**Before**: `init.lua`で直接Use Caseを呼び出し

**After**: Controllerを介して呼び出し

```lua
-- Before
vim.api.nvim_create_user_command("VibingChat", function(opts)
  require("vibing.application.chat.use_case").open()
end, {})

-- After
vim.api.nvim_create_user_command("VibingChat", function(opts)
  require("vibing.presentation.chat.controller").handle_open(opts.args)
end, {})
```

## アーキテクチャ図

### 新しいレイヤー構造

```
┌─────────────────────────────────────────────────────────┐
│ Entry Point (init.lua)                                   │
│   └─→ Vim Commands                                       │
└─────────────────────────────────────────────────────────┘
                           ↓
┌─────────────────────────────────────────────────────────┐
│ Presentation Layer                                       │
│   ├─→ Controller (入力処理・Use Case呼び出し)            │
│   └─→ View (UI表示・ChatBuffer等)                       │
└─────────────────────────────────────────────────────────┘
                           ↓
┌─────────────────────────────────────────────────────────┐
│ Application Layer                                        │
│   └─→ Use Case (ビジネスロジック)                        │
└─────────────────────────────────────────────────────────┘
                           ↓
┌─────────────────────────────────────────────────────────┐
│ Domain Layer                                             │
│   └─→ Domain Model (ChatSession等)                      │
└─────────────────────────────────────────────────────────┘
                           ↓
┌─────────────────────────────────────────────────────────┐
│ Infrastructure Layer                                     │
│   └─→ Adapter, Repository, External Services            │
└─────────────────────────────────────────────────────────┘
```

### 依存関係の方向

```
Entry Point
    ↓
Presentation (Controller & View)
    ↓
Application (Use Case)
    ↓
Domain (Model)
    ↓
Infrastructure (Adapter)
```

**重要**: 矢印の方向（内側）にのみ依存が許される（依存関係逆転の原則）

## 移行ガイド

### Use Caseの呼び出し

**Before**:

```lua
local use_case = require("vibing.application.chat.use_case")
use_case.open()  -- ChatBufferを直接操作
```

**After**:

```lua
local controller = require("vibing.presentation.chat.controller")
controller.handle_open("")  -- Controllerがセッションとビューを管理
```

### セッション管理

**Before**:

```lua
local use_case = require("vibing.application.chat.use_case")
local buffer = use_case.chat_buffer  -- Presentation層のオブジェクト
```

**After**:

```lua
local use_case = require("vibing.application.chat.use_case")
local session = use_case.get_or_create_session()  -- ドメインモデル
```

## メリット

1. **依存関係の明確化**: Application層がPresentation層に依存しなくなった
2. **テスタビリティの向上**: Use CaseがUIから独立してテスト可能
3. **責務の分離**: Controller（入力処理）とView（UI表示）が明確に分離
4. **拡張性の向上**: 新しいUI（Web UI等）を追加しやすい
5. **コードの可読性向上**: レイヤーごとの役割が明確

## 互換性

この変更は内部アーキテクチャの変更であり、**外部APIに変更はありません**。

- すべての`:Vibing*`コマンドは従来通り動作
- プラグイン設定（`setup()`）も変更不要
- `.vibing`ファイルフォーマットも互換性維持

## 今後の課題

1. `M.send()` がまだ `chat_buffer` を引数で受け取っている
   - 理想: Use CaseがViewを受け取らず、イベント経由で通信
2. ChatBufferの責務がまだ大きい
   - View専用クラスとして更なるリファクタが必要
3. テストの追加
   - Use Caseの単体テストを作成

## 参考資料

- [Clean Architecture (Robert C. Martin)](https://blog.cleancoder.com/uncle-bob/2012/08/13/the-clean-architecture.html)
- [Hexagonal Architecture](https://alistair.cockburn.us/hexagonal-architecture/)
