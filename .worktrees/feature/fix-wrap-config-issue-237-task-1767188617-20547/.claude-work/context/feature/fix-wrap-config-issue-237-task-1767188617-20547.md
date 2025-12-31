# Context: feature/fix-wrap-config-issue-237-task-1767188617-20547

## 基本情報

- branch: feature/fix-wrap-config-issue-237-task-1767188617-20547
- task_id: task-1767188617-20547
- 起票: 2024-12-31 22:43

## Issue

- Issue #237: Wrap設定がvibingファイル以外にも適用されてユーザー設定を上書き
- Priority: Critical
- Labels: bug

## 概要

`config.ui.wrap`設定が、vibingバッファ以外の通常のバッファにも適用されてしまい、ユーザーのNeovim設定を意図せず上書きしている。

## 根本原因

- `vim.wo[win].wrap`はwindow-local設定で、そのウィンドウで表示される**すべてのバッファ**に適用される
- Vibingバッファから別のバッファに切り替えた場合でも、ウィンドウの設定は残り続ける

## 推奨修正案

**オプション3（Filetype autocmdでの管理）**を採用:

- `ftplugin/vibing.lua`で設定を管理
- `lua/vibing/utils/ui.lua`から`apply_wrap_config()`呼び出しを削除
- Neovimの標準的なftpluginシステムを活用

## 影響範囲

- `ftplugin/vibing.lua`
- `lua/vibing/utils/ui.lua`
- `lua/vibing/ui/chat_buffer.lua`
- `lua/vibing/ui/output_buffer.lua`
- `lua/vibing/ui/inline_progress.lua`
