---
title: コーディングエージェント
description: Claude Code、Codex などのエージェントに、自分の横で作業を動かし、Kero に進捗を報告することを教えます。
---

# コーディングエージェント

Kero で動くエージェントは、あなたと同じように `kero` コマンドを使えます: 下のペインで開発サーバーを起動し、2 つ目のエージェントにレビューを任せ、テストを待ち、行き詰まったらあなたに知らせます。

<a id="install-the-skill"></a>

## スキルをインストールする

```sh
kero skill setup
```

これで 2 つのものがインストールされます:

- エージェントに CLI を教える **スキル**。Claude Code は `~/.claude/skills/kero` から、Codex、OpenCode などのエージェントは `~/.agents/skills/kero` から読み込みます。
- エージェントがセッションを始めるときに実行される **フック**。エージェントに、どの Kero セッションとペインにいるかを伝えるので、それを調べる手間が省けます。また、名前のないセッションに `fix-login-redirect` のようなタスクにちなんだ名前を付けさせるので、あなたが付ける必要はありません。さらに、エージェント自身のセッションを Kero に伝えるので、再起動のあとなど kerod が再起動したとき、エージェントは[会話を再開](./sessions.md#kerod)します。

フックは、インストールされているエージェントごとに、それぞれが探す場所に置かれます:

| エージェント | フックの場所                                          |
| ------------ | ----------------------------------------------------- |
| Claude Code  | `~/.claude/settings.json` の `SessionStart` フック     |
| Codex        | `~/.codex/hooks.json` の `SessionStart` フック         |
| Pi           | 拡張機能 `~/.pi/agent/extensions/kero.ts`              |
| OpenCode     | プラグイン `~/.config/opencode/plugins/kero`           |

`CLAUDE_CONFIG_DIR`、`CODEX_HOME`、`PI_CODING_AGENT_DIR`、`XDG_CONFIG_HOME` でエージェントのファイルの場所が変わっている場合、Kero はそれに従い、各設定ファイルのほかの部分はそのままにします。

1 つのエージェントだけをセットアップするには、`--agent` に `claude`、`codex`、`pi`、`opencode` のいずれかを渡します。スキルは Kero のバイナリから来るので、Kero をアップデートしたら `kero skill setup` をもう一度実行してください。`kero skill status` で、各部分が最新かどうかがわかります。

```sh
kero skill status    # インストール済みのものと、それが最新かどうか
kero skill show      # スキルを出力
kero skill remove    # スキルとフックをアンインストール
```

フックが働くのはセットアップ後に始めたエージェントのセッションだけで、エージェントが先に確認を求めることもあります:

- **Claude Code** は、信頼したフォルダでのみフックを実行します。
- **Codex** は新しいフックの承認を求めます: `/hooks` で Kero のフックを承認してください。
- **OpenCode** は、バックグラウンドサービスの起動時にプラグインを読み込みます: 作業中のセッションがないときに、一度 `opencode service restart` を実行してください。

OpenCode はエージェントのコマンドをペインではなくバックグラウンドサービスで実行するので、`KERO_SESSION` と `KERO_PANE` がありません。代わりに Kero がエージェントにペインを伝え、エージェントはそれを対象として指定します。同じ理由で、OpenCode のエージェントからの `kero report` はそのペインに届きません。

Kero の外では、フックは何もしません。

## エージェントにできること

自分の横で何かを動かす:

```sh
kero split --down -- npm run dev
kero new -n review -- claude
```

それを操作して結果を読む:

```sh
kero prompt review "review the changes in src/auth"
kero wait tests --for idle,error --timeout 10m
kero read tests -n 60
```

自分の横でテストを実行して、失敗した内容を読む:

```sh
pane=$(kero split --down -- go test ./...)
kero wait "$pane" --exit || kero read "$pane" -n 80
```

状況をあなたに伝える:

```sh
kero report working "Migrating the database" --progress 40
kero report blocked "Approve the production deploy?"
kero report done "Deployed to staging"
```

`blocked` の報告でセッションは*待機中*になり、あなたに通知されます。エージェントがこれを使うのは、あなたなしでは続けられないときだけにしてください。

## リモート操作

**リモート操作** がオン（デフォルト、**設定 › エージェント**）なら、エージェントはアプリ自体も操作できます: `kero focus` でセッションを表示したり、`kero do` でメニューのアクションを実行したりします。エージェントを自分のセッションだけにとどめるには、`remote-control = false` でオフにします。

## 環境変数

すべてのペインには次の変数があります:

| 変数           | 値                             |
| -------------- | ------------------------------ |
| `KERO_SESSION` | ペインのセッションの ID        |
| `KERO_PANE`    | ペインの ID                    |

スクリプトが Kero の中で動いているかどうかは、`$KERO_PANE` で確認できます。
