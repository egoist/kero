---
title: 编程智能体
description: 让 Claude Code、Codex 等智能体在身边运行任务，并在 Kero 中汇报进度。
---

# 编程智能体

在 Kero 中运行的智能体可以像你一样使用 `kero` 命令：在下方窗格里启动开发服务器、把评审交给另一个智能体、等待测试跑完，并在受阻时告诉你。

<a id="install-the-skill"></a>
## 安装技能

```sh
kero skill setup
```

这会安装两样东西：

- 一个**技能**，教智能体使用命令行。Claude Code 从 `~/.claude/skills/kero` 读取；Codex、OpenCode 等智能体从 `~/.agents/skills/kero` 读取。
- 一个**钩子**，在智能体开始会话时运行。它告诉智能体自己位于哪个 Kero 会话和窗格，省得它花时间去查；如果会话还没有名字，就让智能体按任务给它命名，例如 `fix-login-redirect`，不用你动手。它还会把智能体自己的会话告诉 Kero，这样 kerod 重启后（比如电脑重启之后），智能体就能[接上之前的对话](./sessions.md#kerod)。

对于你已安装的智能体，钩子会放在各自查找钩子的位置：

| 智能体      | 钩子位置                                              |
| ----------- | ----------------------------------------------------- |
| Claude Code | `~/.claude/settings.json` 中的 `SessionStart` 钩子     |
| Codex       | `~/.codex/hooks.json` 中的 `SessionStart` 钩子         |
| Pi          | 扩展 `~/.pi/agent/extensions/kero.ts`                  |
| OpenCode    | 插件 `~/.config/opencode/plugins/kero`                 |

如果 `CLAUDE_CONFIG_DIR`、`CODEX_HOME`、`PI_CODING_AGENT_DIR` 或 `XDG_CONFIG_HOME` 改变了智能体文件的位置，Kero 会跟着走，并且不会改动各设置文件里的其他内容。

传入 `--agent` 并指定 `claude`、`codex`、`pi` 或 `opencode`，可以只为一个智能体安装。技能来自你的 Kero 程序本身，所以更新 Kero 后请再运行一次 `kero skill setup`。`kero skill status` 会告诉你各部分是否为最新。

```sh
kero skill status    # 已安装什么，是否为最新
kero skill show      # 打印技能内容
kero skill remove    # 卸载技能和钩子
```

钩子只对安装之后启动的智能体会话生效，而且智能体可能会先征求你的同意：

- **Claude Code** 只在你信任的文件夹中运行钩子。
- **Codex** 会请你批准新钩子：用 `/hooks` 批准 Kero 的钩子。
- **OpenCode** 在其后台服务启动时加载插件：趁没有会话在忙时，运行一次 `opencode service restart`。

OpenCode 在后台服务而非窗格中运行智能体的命令，所以这些命令拿不到 `KERO_SESSION` 和 `KERO_PANE`。Kero 会改为把窗格告诉智能体，由它显式指定为目标。出于同样的原因，OpenCode 智能体执行的 `kero report` 无法到达它的窗格。

在 Kero 之外，钩子什么也不做。

## 智能体能做什么

在身边运行任务：

```sh
kero split --down -- npm run dev
kero new -n review -- claude
```

操控它并读取结果：

```sh
kero prompt review "review the changes in src/auth"
kero wait tests --for idle,error --timeout 10m
kero read tests -n 60
```

在旁边跑测试，并读取失败信息：

```sh
pane=$(kero split --down -- go test ./...)
kero wait "$pane" --exit || kero read "$pane" -n 80
```

告诉你进展如何：

```sh
kero report working "Migrating the database" --progress 40
kero report blocked "Approve the production deploy?"
kero report done "Deployed to staging"
```

`blocked` 报告会把会话变为*等待中*并通知你，所以智能体只应在离开你就无法继续时使用它。

## 远程控制

开启**远程控制**后（默认开启，位于**设置 › 智能体**），智能体还能操控应用本身：用 `kero focus` 显示某个会话，或用 `kero do` 执行菜单操作。设置 `remote-control = false` 可将其关闭，让智能体只能操作自己的会话。

## 环境变量

每个窗格都会获得：

| 变量           | 值                             |
| -------------- | ------------------------------ |
| `KERO_SESSION` | 窗格所在会话的 id              |
| `KERO_PANE`    | 窗格的 id                      |

检查 `$KERO_PANE` 即可判断脚本是否运行在 Kero 中。
