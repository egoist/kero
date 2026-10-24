---
title: コマンドライン
description: kero CLI で、シェルやスクリプトから Kero のセッションとペインを操作します。
---

# コマンドライン

`kero` コマンドは、あなたのシェル、スクリプト、エージェントなど、どのシェルからでもセッションを操作できます。**Kero › コマンドラインツールをインストール…** でインストールします。

## 対象

ほとんどのコマンドは**対象**を取ります: セッションかペインです。対象には次のものを指定できます:

- ID、またはその一意な前方部分
- セッションの名前
- セッション（フォーカスのあるペインを表す）

Kero の中では、`$KERO_SESSION` と `$KERO_PANE` がコマンドを実行するセッションとペインを示し、それがデフォルトの対象になります。

## セッションとペイン

```sh
kero ls                          # すべてのセッションとそのペイン
kero new -n api -d ~/code/api    # セッションを開始し、その ID を出力
kero new -- npm run dev          # コマンドを実行するセッションを開始
kero split --down -- npm test    # このペインの横にペイン
kero split --url localhost:3000  # ページを表示するブラウザペイン
kero rename api backend          # セッション名を変更
kero focus backend               # アプリで表示
kero close backend               # セッションを終える（ペインを指定するとそのペイン）
kero restart <pane>              # 終了したペインのシェルを再び開始
```

`kero new` のオプション:

| フラグ                      | 意味                                            |
| --------------------------- | ----------------------------------------------- |
| `-p`, `--project <name\|id>` | 入れるプロジェクト（デフォルト: ディレクトリから決まる） |
| `-n`, `--name <name>`       | セッションに名前を付ける                        |
| `-d`, `--dir <dir>`         | そこで開始する（デフォルト: 現在のディレクトリ） |
| `-f`, `--focus`             | アプリで表示する                                |
| `-w`, `--wait`              | コマンドの終了を待ち、その終了ステータスで終了する |
| `-u`, `--url <url>`         | シェルの代わりに、ページを表示するブラウザを開く |

## 入力と読み取り

```sh
kero send api "npm run migrate" --enter   # テキストを入力してから Enter を押す
kero send api -e 'y\n'                    # \n \r \t \e \xHH のエスケープを解釈
kero key api ctrl+c                       # キーを押す
kero read api -n 40                       # 画面の最後の 40 行
kero read api -a                          # スクロールバックを含む画面
```

`kero key` は `enter`、`tab`、`escape`、`up`、`down`、`left`、`right`、`backspace` と、`ctrl+c` や `ctrl+d` のような修飾キーを理解します。

## 待機

```sh
kero wait api                             # 作業が止まるまで
kero wait api --for waiting,error --timeout 10m
kero prompt review "summarize the diff"   # 送信 + Enter、待機、画面を出力
```

`kero wait` は戻るときにペインの状態を出力します。`kero prompt` はテキストと Enter を送り、ペインの作業が止まるまで待ってから画面を出力します。ほかのエージェントに何かを尋ねる最も手早い方法です。

### コマンドの終了を待つ

`make test` のようなコマンドは*作業中*と表示されないので、終了を待つには `--wait` を付けて開始します。すると `kero` はそのコマンド自身の終了ステータスで終了します:

```sh
if kero split --down --wait -- make test; then
  echo "tests passed"
fi
```

`kero wait --exit` は、開始時のコマンドをすでに実行しているペインに対して同じことをします:

```sh
pane=$(kero split --down -- go test ./...)
# … ほかのことをする …
kero wait "$pane" --exit --timeout 10m
echo "go test exited with $?"
```

コマンドの終了後も出力とともにペインは開いたままなので、`kero read` で読めます。コマンドの終了を判断できない `cmd` をシェルにしている場合、コマンドの終了待ちは使えません。

## イベントの監視

`kero events` は、セッションとペインに起きたことを起きたときに 1 イベント 1 行で出力し、止めるまで続けます。スクリプトは `kero status` をポーリングせずに、すべてのエージェントを一度に追えます。

```sh
kero events                               # すべてのセッション
kero events api                           # 1 つのセッション、または 1 つのペイン
kero events -p kero                       # 1 つのプロジェクトのセッション
kero events --for waiting,error           # これらの状態になったペインだけ
kero events --json | jq -r .name          # 1 行に 1 つの JSON オブジェクト
kero events --for waiting --once          # 最初の 1 件で終了
```

```
12:04:31  api x78n9ss  working → waiting  Allow Bash: rm -rf dist?
12:04:40  api  renamed api → backend
```

| イベント | いつ | フィールド |
| --- | --- | --- |
| `pane.status` | ペインの状態が変わったとき | `pane`、`from`、`to`、`message`、`kind`、`agent`。exited になったときは `exitCode` も |
| `command.exited` | ペインの開始時のコマンドが終わり、シェルが続くとき | `pane`、`exitCode` |
| `pane.created`、`pane.closed` | ペインが開始または終了したとき | `pane` |
| `session.created`、`session.closed` | セッションが開始または終了したとき | |
| `session.renamed` | セッションの名前が変わったとき | `from`、`to` |
| `notice` | セッション内のプログラムがデスクトップ通知を送ったとき | `pane`、`title`、`body` |

`--json` では、どのイベントにも `event`、`time`（unix ミリ秒）、`session`、`project`、`name`（サイドバーに表示されるセッション名）が付きます。

`kero events` が報告するのは今からの変化です。すでにあるものは `kero ls --json` で確認します。対象を指定すると、対象が閉じたときに止まります。`--once` は最初に一致したイベントで終了し、対象が先に閉じるか `--timeout` が過ぎると `1` で終了します。kerod は状態が落ち着いてから送るので、一瞬だけの状態（短い作業中など）は出ないことがあります。

<a id="browsing"></a>

## ブラウザの操作

`kero browser` は、`kero send` と `kero read` がターミナルを操作するのと同じように、ブラウザペインのページを操作します: クリック、入力、ページの読み取り、スクリーンショット。対象はブラウザペイン、またはセッション（そのブラウザ）です。対象を指定しなければ、実行したセッションのブラウザを操作します。

```sh
kero split --url localhost:3000            # ページを開き、ペインの ID を出力
kero browser open localhost:3000/todos     # ページへ移動し、読み込みを待つ
kero browser type '#new-todo' "Buy milk" --enter
kero browser wait '.todo-list li'          # 要素が表示されるまで
kero browser wait --text "1 item left"     # テキストが表示されるまで
kero browser text                          # ページのテキスト
kero browser text h1                       # 要素のテキスト
kero browser click 'button[type=submit]'
kero browser screenshot -o page.png
kero browser eval 'document.title'
```

| コマンド                        | 動作 |
| ------------------------------- | ---- |
| `open <url>`                    | ページへ移動し、読み込みを待つ |
| `back`、`forward`、`reload`     | 戻る、進む、または再読み込みして、それを待つ |
| `text [selector]`               | ページの表示テキスト、または最初に一致した要素のテキストを出力 |
| `html [selector]`               | ページ、または要素の HTML を出力 |
| `click <selector>`              | マウスと同じように要素をクリック |
| `type <selector> <text…>`       | フィールドの内容を置き換えてテキストを入力。`--enter` を付けるとその後 Enter を押し、フォームを送信する |
| `wait [selector] [--text text]` | 要素かテキストが表示されるまで待つ。どちらもなければページの読み込みまで |
| `eval <js…>`                    | ページで JavaScript を実行し、その値を出力: 文字列はそのまま、それ以外は JSON |
| `screenshot [-o file.png]`      | ページの画像を保存し、その場所を出力。`-o -` で標準出力に書き出す |

セレクタは CSS セレクタです。シェルでは引用符で囲んでください。要素が必要なコマンドは要素が現れるのを待ち、`--timeout`（デフォルト `10s`）でそれらとページの読み込みにかけてよい時間を設定します。`type` と `eval` は、`-` で標準入力からテキストを受け取ります。

クリックと入力は本物のマウスとキーボードと同じイベントを送るので、React などのフレームワークで作られたページもそれを受け取ります。スクリーンショットにはペインが画面に表示されている必要があります: 先に `kero focus` で表示してください。それ以外は、表示されているかどうかにかかわらず、どのブラウザペインでも動きます。

`kero do` と同じく、`kero browser` には **設定 › エージェント** のリモート操作と、アプリが開いていることが必要です。

## 状態

```sh
kero status api --json                    # 状態、プログラム、ディレクトリ
kero report working "Running migrations"  # 自分の状態を報告
kero notify "Need your input"             # このペインを対応が必要なものとして示す
```

状態については[状態と通知](./status.md)を参照してください。

## 変更

```sh
kero diff                                 # ペインの未コミットの変更を git diff の形式で
kero diff --turn                          # エージェントが直前のターンで変更したもの
kero diff review --branch                 # デフォルトブランチ以降
```

[変更](./changes.md)を参照してください。

## 構成とセットアップ

```sh
kero config path                 # 設定ファイルの場所
kero config show                 # すべてのキーとその値
kero config show --defaults      # すべてのキーの初期値
kero config edit                 # $EDITOR で開く
kero config check                # 不明なキーと不正な値を報告
kero projects                    # プロジェクトを一覧
kero skill setup                 # コーディングエージェントに kero の使い方を教える
kero daemon status|stop|restart  # kerod を管理
kero daemon install-service      # マシンの起動とともに kerod を実行（systemd、launchd）
kero daemon serve                # サービスマネージャ向けに kerod をフォアグラウンドで実行
kero clients                     # kerod に接続しているもの
```

## ほかのマシン

コマンドの前に `-H <host>` を付けるか `$KERO_HOST` を設定すると、セッションに対するコマンドを別のマシンの kerod に向けられます: 追加したホスト、または `me@devbox` や `wsl://Ubuntu` のようなアドレスです。[リモートホスト](./remote.md)を参照してください。

```sh
kero hosts                       # 追加したホスト
kero hosts add devbox me@devbox  # 追加する（アプリにも表示される）
kero hosts check devbox          # 接続して、結果を表示
kero hosts install devbox        # SSH でそこに Kero をインストール
kero -H devbox ls
kero -H devbox new -n review -- claude
kero -H devbox daemon update     # そこの Kero をこちらのバージョンにアップデート
```

ペインの中では、`kero` はアプリがどこにあっても、ペインが動いているマシンの kerod と通信します。

## アプリのアクションを実行する

`kero do` は、メニューと同じアプリのアクションをどれでも実行します。**設定 › エージェント** のリモート操作（デフォルトでオン）が必要です。

```sh
kero actions                     # 一覧を表示
kero do pane.split.right
kero do pane.browser url=localhost:3000
kero do sidebar.toggle
```

## 終了ステータス

| コード | 意味                                 |
| ------ | ------------------------------------ |
| `0`    | 成功                                 |
| `1`    | 失敗                                 |
| `2`    | 使い方の誤り                         |
| `3`    | 対象が存在しない、またはあいまい     |
| `4`    | kerod に接続できない                 |

プログラムを待つコマンド（`kero wait --exit` と `--wait`）は、代わりにそのプログラムの終了ステータスで終了します。ペインのシェルがエラーで終了したときの `kero wait` も同じです。タイムアウトした待機は `1` で終了します。

`ls`、`status`、`projects` に `--json` を付けると、機械で読める形式で出力します。
