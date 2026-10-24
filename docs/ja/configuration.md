---
title: 設定
description: Kero の設定ファイルと、そのキーとデフォルト値。
---

# 設定

Kero は設定をひとつのプレーンテキストファイルに保存します。設定ウインドウ（<kbd>⌘</kbd> <kbd>,</kbd>）はコメントと順序を保ったままこのファイルを編集し、手で編集したときは Kero が読み込み直します。

## ファイル

Kero は次の順に優先して読み込みます:

1. `$KERO_CONFIG`
2. `$XDG_CONFIG_HOME/kero/config`
3. `~/.config/kero/config`

構文は Ghostty と同じです: 1 行に 1 つの `key = value`、コメントは `#`、リストを持つキーは行を繰り返します。Ghostty と同じ意味のキーには、Ghostty と同じ名前が付いています。

```ini
# ~/.config/kero/config
font-size = 14
theme = light:GitHub Light Default,dark:Catppuccin Mocha
cursor-style = bar

env = EDITOR=nvim
env = HOMEBREW_NO_AUTO_UPDATE=1

keybind = cmd+shift+d=pane.split.down
```

ファイルには変更したものだけを書けば十分です。それ以外はデフォルトのままです。

```sh
kero config edit              # $EDITOR で開く
kero config show              # すべてのキーと現在の値
kero config check             # 不明なキーと不正な値を報告
```

## 一般

| キー                    | デフォルト | 説明                                                          |
| ----------------------- | ---------- | ------------------------------------------------------------- |
| `new-session-directory` | `current`  | 新規セッションの開始場所: `current`、`project`、`home`        |
| `session-name`          | `focused`  | 名前を付けていないセッションの名前の付け方: `focused`、`lead`、`folder`（[詳しく](./sessions.md#how-an-unnamed-session-is-named)） |
| `focus-follows-mouse`   | `false`    | ポインタが入ったペインにフォーカスを移す                      |
| `confirm-close`         | `true`     | プログラムが実行中のペインを閉じる前に確認する                |
| `restore-sessions`      | `true`     | 再起動のあとなど kerod が再起動したら、セッションを再び開始する |
| `resume-agents`         | `true`     | セッションの再開時に、各ペインで動いていたエージェントの会話を再開する |

## 外観

| キー                 | デフォルト | 説明                                                            |
| -------------------- | ---------- | --------------------------------------------------------------- |
| `window-theme`       | `system`   | アプリの外観: `system`、`light`、`dark`                         |
| `language`           | `system`   | アプリの言語: `system`、`en`、`ja`、`zh-Hans`                   |
| `background`         | `petal`    | ウインドウの背景: `petal`、`mist`、`meadow`、`dusk`、`plain`    |
| `window-translucent` | `true`     | ウインドウからデスクトップを透けて見せる                        |

## ターミナル

| キー                  | デフォルト | 説明                                                                     |
| --------------------- | ---------- | ------------------------------------------------------------------------ |
| `theme`               | `kero`     | ターミナルの色: `kero`、任意の Ghostty テーマ、または `light:<theme>,dark:<theme>` |
| `font-family`         |            | 空欄なら Kero に付属の JetBrains Mono Nerd Font、`monospace` ならシステムのもの、またはインストール済みの任意のファミリー |
| `font-size`           | `13`       | ポイント単位                                                             |
| `font-weight`         | `400`      | `100` から `900`                                                         |
| `line-height`         | `1.22`     | フォントの行の高さに対する倍率                                           |
| `font-ligatures`      | `true`     | フォントが描くとおりに文字をつなげる                                     |
| `font-thicken`        | `false`    | Ghostty と同じく、線を太くする                                           |
| `minimum-contrast`    | `3`        | テキストが背景に対して保つ最小のコントラスト。`1`（なし）から `21`。Ghostty と同じく、暗い背景向けの色が明るい背景でも読めるようにする |
| `dim-unfocused-terminals` | `true` | セッションに複数のペインがあるとき、使用中でないターミナルを薄くする |
| `cursor-style`        | `block`    | `block`、`bar`、`underline`。プログラムが変更することがある              |
| `cursor-style-blink`  | `true`     | カーソルを点滅させる                                                     |
| `macos-option-as-alt` | `false`    | Option でプログラムに Alt（メタ）を送る                                  |
| `copy-on-select`      | `false`    | 選択したものをクリップボードにコピーする                                 |
| `clipboard-read`      | `ask`      | プログラムによるクリップボードの読み取り（OSC 52）: `ask`、`allow`、`deny` |
| `right-click-action`  | `context-menu` | `context-menu`、`paste`、`copy-or-paste`                             |

## シェル

| キー               | デフォルト | 説明                                                           |
| ------------------ | ---------- | -------------------------------------------------------------- |
| `command`          |            | 新しいペインのシェル。空欄ならログインシェル                   |
| `env`              |            | `NAME=value` として、すべてのペインの環境変数に追加する。繰り返して指定する |
| `scrollback-limit` | `4`        | 各ペインが保持する出力（メガバイト単位）。`0` で保持しない     |

## 通知

| キー                | デフォルト | 説明                                           |
| ------------------- | ---------- | ---------------------------------------------- |
| `notify-on-waiting` | `true`     | セッションが対応を求めたとき                   |
| `notify-on-done`    | `true`     | エージェントが完了したとき                     |
| `notify-on-error`   | `true`     | プログラムが失敗を報告したとき                 |
| `notify-sound`      | `false`    | 通知とともにサウンドを再生する                 |
| `dock-badge`        | `true`     | 対応が必要なセッションの数を Dock アイコンに表示する |
| `dock-bounce`       | `false`    | セッションが対応を求めたときに Dock アイコンを 1 回弾ませる |

## エージェント

| キー             | デフォルト | 説明                                                |
| ---------------- | ---------- | --------------------------------------------------- |
| `remote-control` | `true`     | `kero do` と `kero focus` によるアプリの操作を許可する |

## ホスト

アプリにセッションを表示し、`kero -H` で接続する、ほかのマシン。[リモートホスト](./remote.md)を参照してください。

| キー           | デフォルト | 説明 |
| -------------- | ---------- | ---- |
| `host`         |            | `name=address` 形式のホスト: SSH なら `me@devbox` や `ssh://…`、WSL なら `wsl://distro`、kerod の tailnet リスナーなら `http(s)://…`。後ろに ` remote-control` を付けるとそのプログラムにアプリの操作を許可し、` color=teal`（red、orange、amber、green、teal、blue、purple、pink）を付けるとそのセッションに色を付けられる。ホストごとに繰り返して指定する |
| `listen`       |            | ほかのマシンの Kero からこのマシンへの接続を許可する: Tailscale アドレスで待ち受けるなら `tailnet://:7373`、Tailscale Serve なら `tailnet-serve://`。それぞれ繰り返して指定する |
| `listen-allow` |            | マシンの所有者以外に接続を許可する相手: tailnet のログイン、`tag:name`、または tailnet 上の誰でもなら `*`。それぞれ繰り返して指定する |
| `remote-updates` | `false`  | ほかのマシンの Kero が、ここの Kero アプリをそのバージョンにアップデートすることを許可する（アプリは再起動する） |

## Git

| キー          | デフォルト | 説明                                                                                              |
| ------------- | ---------- | ------------------------------------------------------------------------------------------------- |
| `git-status`  | `true`     | 各セッションのブランチと[変更](./changes.md)を表示する                                            |
| `diff-layout` | `auto`     | 変更パネルの差分: `unified`、`split`（左右に並べる）、または広くなると左右に並べる `auto`          |

<a id="browser"></a>

## ブラウザ

| キー                  | デフォルト                 | 説明                                                                                |
| --------------------- | -------------------------- | ----------------------------------------------------------------------------------- |
| `browser-block-ads`   | `true`                     | ブラウザペインで[広告とトラッカーをブロック](./panes.md#blocking-ads)する           |
| `browser-filter-list` | `easylist`、`easyprivacy`  | ブロックに使うフィルタリスト。リストごとに繰り返す。空欄ならなし                    |

`browser-filter-list` には、Kero が提供するリストの名前か、Adblock Plus 構文の任意のリストの `https://` URL を指定します:

| 名前               | リスト                                                              |
| ------------------ | ------------------------------------------------------------------- |
| `easylist`         | EasyList: 広告                                                      |
| `easyprivacy`      | EasyPrivacy: トラッカーとアクセス解析                               |
| `peter-lowe`       | Peter Lowe's list: 広告とトラッカーのサーバー                       |
| `easylist-china`   | EasyList China: 中国語サイトの広告                                  |
| `fanboy-cookie`    | EasyList Cookie List: Cookie の通知と同意バナー                     |
| `fanboy-social`    | Fanboy's Social Blocking List: ソーシャルメディアのボタンと埋め込み |
| `fanboy-annoyance` | Fanboy's Annoyance List: ポップアップと勧誘。上の 2 つも含む        |

```ini
browser-filter-list = easylist
browser-filter-list = easyprivacy
browser-filter-list = fanboy-cookie
browser-filter-list = https://example.com/my-filters.txt
```

<a id="keyboard"></a>

## キーボード

`keybind` は `<keys>=<action>` の形でアクションの割り当てを変えます。割り当てごとに繰り返します。キーを空けるには、アクションに `unbind` を使います。

```ini
keybind = cmd+shift+d=pane.split.down
keybind = cmd+k=palette.open
keybind = cmd+b=unbind
```

すべてのアクション ID は `kero actions` で確認できます。デフォルトは[キーボードショートカット](./shortcuts.md)を参照してください。
