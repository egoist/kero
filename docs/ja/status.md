---
title: 状態と通知
description: Kero が各ペインの作業を追跡する仕組みと、プログラムが自分の状態を報告する方法。
---

# 状態と通知

Kero はすべてのペインが何をしているかを追跡するので、エージェントに作業を任せて、対応が必要になったときに戻ってくればよいのです。

## ペインの状態

すべてのペインには状態があり、サイドバーに表示されます:

| 状態      | 意味                                          |
| --------- | --------------------------------------------- |
| `working` | プログラムが作業中: 考えているエージェント、それが実行するツール |
| `waiting` | あなたの対応が必要: 質問、許可の確認          |
| `idle`    | 何も起きていない。シェルがプロンプトを表示している |
| `error`   | プログラムが失敗を報告した                    |
| `exited`  | プログラムが終了した。ペインは出力を保持する  |

Kero は、コーディングエージェントの状態を画面の表示から判断します: スピナー、許可の確認、あなたを待つプロンプト。ペインのサイズを変えたときのように同じ画面を描き直しても、何も変わりません。ほかのプログラムは、タイトルにスピナーが表示されている間か、[状態を報告](#reporting-status-from-a-program)したときに `working` になります。

セッションにはペインの状態が表示され、対応が必要なセッションは目立ちます。<kbd>⌘</kbd> <kbd>J</kbd> で次のセッションへ移動できます。

## 通知

ほかの場所を見ている間に次のことが起きると、Kero が通知します:

- セッションがあなたの対応を求めたとき（`notify-on-waiting`）
- エージェントが完了したとき（`notify-on-done`）
- プログラムが失敗を報告したとき（`notify-on-error`）

プログラム自身のデスクトップ通知は、ほかのターミナルと同じように表示され、状態には影響しません。

Dock アイコンには対応が必要なセッションの数が表示され（`dock-badge`）、対応が必要になったときに 1 回弾ませることもできます（`dock-bounce`）。[設定](./configuration.md)を参照してください。

<a id="reporting-status-from-a-program"></a>

## プログラムから状態を報告する

プログラムやエージェントは、`kero report` で自分が何をしているかを Kero に伝えられます:

```sh
kero report working "Migrating the database" --progress 40
kero report blocked "Approve the production deploy?" --kind permission
kero report done "Deployed to staging"
kero report clear
```

状態は次のとおりです:

| 状態      | 意味                                                       |
| --------- | ---------------------------------------------------------- |
| `idle`    | 休止中。次の指示を待っている                               |
| `working` | 作業中。`--progress` でパーセンテージを示す                |
| `blocked` | あなたなしでは先に進めない。`--kind` で何が必要かを示す    |
| `done`    | 完了し、まだあなたが確認していない                         |
| `error`   | 失敗して停止した                                           |
| `clear`   | 状態ではない: プログラムが報告したものを取り除く           |

Kero はメッセージをサイドバーに表示します。`blocked` の報告でセッションは*待機中*になり、`done` や `blocked` は、あなたが離れているときに通知します。`--kind` は `permission`（何かを承認する）、`question`（回答を入力する）、`auth`（ログインやトークン）のいずれかです。

`working` と `blocked` はプログラムが動いている間だけ続き、終了すると消えます。`done` と `error` はペインに入力するまで残るので、離れている間に終わったプログラムの結果を後で確認できます。中断されたプログラムは `idle` を報告してください。

状態を変えずに、ペインを対応が必要なものとして示すには:

```sh
kero notify "Need your API key to continue"
```

### 1 つのペインで複数のタスク

複数のことを同時に行うプログラムは、それぞれを `--id` で報告し、`--title` で名前を付けられます:

```sh
kero report working "Deploying v2.4.1" --app deploy
kero report working "Pushing image" --id us-east --title "US East" --progress 40
kero report blocked "Approve deploy to production?" --id eu-west --title "EU West" --kind permission
kero report clear --id us-east
```

各報告はその ID の下にあったものを置き換えるので、`--app` と `--title` は毎回繰り返してください。ID には子を持たせられ（`build/test` は `build` の子）、ID を指定した `clear` はそれと子を取り除きます。ペインには最も対応が必要な報告が表示されます: `blocked`、`working`、`error`、`done` の順です。

`--app` は `cargo` や `terraform` のようなプログラムの安定した名前で、その下の ID が引き継ぎます。

### エスケープシーケンス

`kero report` は OSC 7501 エスケープシーケンス、つまり [Program Status Protocol](https://www.superlogical.com/rex/docs/build/program-status) を書き出します。どのプログラムも自分で書き出せます。これは Kero 独自のものではありません: 採用したプログラムは、これを読むすべてのターミナルに報告できます。

```txt
ESC ] 7501 ; state=<state> [:id=<id>] [:kind=<kind>] [:progress=<n>] [:app=<app>] [:title=<base64>] [:msg=<base64>] ESC \
```

フィールドは `:` で区切られ、`msg` と `title` は Base64 でエンコードした UTF-8 です。たとえばシェルでは:

```sh
status() {
  printf '\e]7501;state=%s:msg=%s\e\\' "$1" "$(printf '%s' "$2" | base64 | tr -d '\n')"
}
status working "Syncing photos"
rsync -a ~/Photos backup:/photos && status done "Photos synced" || status error "rsync failed"
```

プログラムは `ESC ] 7501 ; ? ESC \` を書き出すことで、ターミナルがこのプロトコルを読むかどうかを確認できます。Kero は同じシーケンスで応答します。

ConEmu のシーケンス OSC 9;4 でプログラムが表示する進捗バーでは、`working` になりません: Neovim などのエディタは、言語サーバーの読み込み中にそれを表示するからです。Kero がそれを読むのは、そのやり方で作業を示すコーディングエージェントの状態を判断するときだけです。プログラムは OSC 7501 で状態を報告してください。
