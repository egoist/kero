---
title: キーボードショートカット
description: Kero のデフォルトのキーボードショートカットと、割り当てを変えるためのアクション ID。
---

# キーボードショートカット

どれも **設定 › キーボード**、または[設定ファイル](./configuration.md#keyboard)の `keybind` で割り当てを変えられます。

Windows と Linux では、<kbd>Ctrl</kbd> と文字キーの組み合わせはシェルのもの（<kbd>Ctrl</kbd> <kbd>D</kbd>、<kbd>Ctrl</kbd> <kbd>R</kbd>、<kbd>Ctrl</kbd> <kbd>W</kbd>…）なので、Kero のショートカットは Windows Terminal と同じく <kbd>Shift</kbd> を加えるか、<kbd>Alt</kbd> を使います。ダッシュは、そのアクションにショートカットがないことを示します。

## Kero

| アクション                       | macOS                                  | Windows と Linux                              | アクション ID    |
| -------------------------------- | -------------------------------------- | --------------------------------------------- | ---------------- |
| 設定…                            | <kbd>⌘</kbd> <kbd>,</kbd>              | <kbd>Ctrl</kbd> <kbd>,</kbd>                  | `settings.open`  |
| 終了（セッションは動き続ける）   | <kbd>⌘</kbd> <kbd>Q</kbd>              | <kbd>Ctrl</kbd> <kbd>Shift</kbd> <kbd>Q</kbd> |                  |
| 終了してすべてのセッションを終える… | <kbd>⌘</kbd> <kbd>⌥</kbd> <kbd>Q</kbd> | –                                          | `app.quitAll`    |

## セッション

| アクション                   | macOS                                  | Windows と Linux                              | アクション ID       |
| ---------------------------- | -------------------------------------- | --------------------------------------------- | ------------------- |
| 新規セッション               | <kbd>⌘</kbd> <kbd>T</kbd>              | <kbd>Ctrl</kbd> <kbd>Shift</kbd> <kbd>T</kbd> | `session.new`       |
| ホームで新規セッション       | <kbd>⌘</kbd> <kbd>⇧</kbd> <kbd>T</kbd> | –                                             | `session.newHome`   |
| プロジェクトを開く…          | <kbd>⌘</kbd> <kbd>O</kbd>              | <kbd>Ctrl</kbd> <kbd>Shift</kbd> <kbd>O</kbd> | `project.open`      |
| セッションへ移動…            | <kbd>⌘</kbd> <kbd>P</kbd>              | <kbd>Ctrl</kbd> <kbd>Shift</kbd> <kbd>P</kbd> | `palette.open`      |
| 対応が必要なセッションへ移動 | <kbd>⌘</kbd> <kbd>J</kbd>              | <kbd>Ctrl</kbd> <kbd>Shift</kbd> <kbd>J</kbd> | `session.attention` |
| 次のセッション               | <kbd>⌘</kbd> <kbd>⇧</kbd> <kbd>]</kbd> | <kbd>Ctrl</kbd> <kbd>PgDn</kbd>               | `session.next`      |
| 前のセッション               | <kbd>⌘</kbd> <kbd>⇧</kbd> <kbd>[</kbd> | <kbd>Ctrl</kbd> <kbd>PgUp</kbd>               | `session.previous`  |
| セッション名を変更           | <kbd>⌘</kbd> <kbd>R</kbd>              | –                                             | `session.rename`    |
| ペインを再起動               | <kbd>⌘</kbd> <kbd>⇧</kbd> <kbd>R</kbd> | <kbd>Ctrl</kbd> <kbd>Shift</kbd> <kbd>R</kbd> | `pane.restart`      |
| 閉じる                       | <kbd>⌘</kbd> <kbd>W</kbd>              | <kbd>Ctrl</kbd> <kbd>Shift</kbd> <kbd>W</kbd> | `pane.close`        |
| セッションを閉じる           | <kbd>⌘</kbd> <kbd>⇧</kbd> <kbd>W</kbd> | –                                             | `session.close`     |

<kbd>⌘</kbd> <kbd>1</kbd>–<kbd>9</kbd>（Windows と Linux では <kbd>Ctrl</kbd> <kbd>1</kbd>–<kbd>9</kbd>）でサイドバーのセッションへ、<kbd>Ctrl</kbd> <kbd>Tab</kbd> で次のセッションへ移動します。

## ペイン

| アクション         | macOS                                  | Windows と Linux                                  | アクション ID      |
| ------------------ | -------------------------------------- | ------------------------------------------------- | ------------------ |
| 右に分割           | <kbd>⌘</kbd> <kbd>D</kbd>              | <kbd>Alt</kbd> <kbd>Shift</kbd> <kbd>=</kbd>      | `pane.split.right` |
| 下に分割           | <kbd>⌘</kbd> <kbd>⇧</kbd> <kbd>D</kbd> | <kbd>Alt</kbd> <kbd>Shift</kbd> <kbd>-</kbd>      | `pane.split.down`  |
| 新規ブラウザペイン | <kbd>⌘</kbd> <kbd>⇧</kbd> <kbd>B</kbd> | <kbd>Alt</kbd> <kbd>Shift</kbd> <kbd>B</kbd>      | `pane.browser`     |
| 場所を開く         | <kbd>⌘</kbd> <kbd>L</kbd>              | –                                                 | `browser.address`  |
| ペインを拡大       | <kbd>⌘</kbd> <kbd>⇧</kbd> <kbd>↩</kbd> | <kbd>Ctrl</kbd> <kbd>Shift</kbd> <kbd>Enter</kbd> | `pane.zoom`        |
| 次のペイン         | <kbd>⌘</kbd> <kbd>]</kbd>              | <kbd>Ctrl</kbd> <kbd>Shift</kbd> <kbd>]</kbd>     | `pane.next`        |
| 前のペイン         | <kbd>⌘</kbd> <kbd>[</kbd>              | <kbd>Ctrl</kbd> <kbd>Shift</kbd> <kbd>[</kbd>     | `pane.previous`    |
| 左のペイン         | <kbd>⌘</kbd> <kbd>⌥</kbd> <kbd>←</kbd> | <kbd>Alt</kbd> <kbd>←</kbd>                       | `pane.left`        |
| 右のペイン         | <kbd>⌘</kbd> <kbd>⌥</kbd> <kbd>→</kbd> | <kbd>Alt</kbd> <kbd>→</kbd>                       | `pane.right`       |
| 上のペイン         | <kbd>⌘</kbd> <kbd>⌥</kbd> <kbd>↑</kbd> | <kbd>Alt</kbd> <kbd>↑</kbd>                       | `pane.up`          |
| 下のペイン         | <kbd>⌘</kbd> <kbd>⌥</kbd> <kbd>↓</kbd> | <kbd>Alt</kbd> <kbd>↓</kbd>                       | `pane.down`        |

## 表示

| アクション             | macOS                                  | Windows と Linux                              | アクション ID    |
| ---------------------- | -------------------------------------- | --------------------------------------------- | ---------------- |
| サイドバーの切り替え   | <kbd>⌘</kbd> <kbd>B</kbd>              | <kbd>Ctrl</kbd> <kbd>Shift</kbd> <kbd>B</kbd> | `sidebar.toggle` |
| 変更の切り替え         | <kbd>⌥</kbd> <kbd>⌘</kbd> <kbd>G</kbd> | <kbd>Ctrl</kbd> <kbd>Shift</kbd> <kbd>G</kbd> | `changes.toggle` |
| 拡大                   | <kbd>⌘</kbd> <kbd>=</kbd>              | <kbd>Ctrl</kbd> <kbd>=</kbd>                  | `text.bigger`    |
| 縮小                   | <kbd>⌘</kbd> <kbd>-</kbd>              | <kbd>Ctrl</kbd> <kbd>-</kbd>                  | `text.smaller`   |
| 実際のサイズ           | <kbd>⌘</kbd> <kbd>0</kbd>              | <kbd>Ctrl</kbd> <kbd>0</kbd>                  | `text.reset`     |
