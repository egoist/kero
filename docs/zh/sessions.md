---
title: 会话与项目
description: Kero 如何按项目组织终端会话，并让它们在 kerod 中持续运行。
---

# 会话与项目

Kero 将你的工作分为两层：项目（文件夹）包含会话（任务），每个会话都在 kerod 中持续运行，直到你关闭它。

## 会话

**会话**是一个工作单元：一项任务、一个智能体、一个长期运行的进程。它包含一个或多个[窗格](./panes.md)，每个窗格运行一个 shell 或一个程序。

| 操作                       | 快捷键                                       |
| -------------------------- | -------------------------------------------- |
| 新建会话                   | <kbd>⌘</kbd> <kbd>T</kbd>                    |
| 在主目录新建会话           | <kbd>⌘</kbd> <kbd>⇧</kbd> <kbd>T</kbd>       |
| 前往会话…                  | <kbd>⌘</kbd> <kbd>P</kbd>                    |
| 跳到需要你的会话           | <kbd>⌘</kbd> <kbd>J</kbd>                    |
| 下一个 / 上一个会话        | <kbd>⌘</kbd> <kbd>⇧</kbd> <kbd>]</kbd> / <kbd>[</kbd> |
| 重命名会话                 | <kbd>⌘</kbd> <kbd>R</kbd>                    |
| 关闭会话                   | <kbd>⌘</kbd> <kbd>⇧</kbd> <kbd>W</kbd>       |

按任务给会话命名，比如 `fix-login-redirect` 或 `review-pr-42`，这样就能在边栏中找到它们，也能在[命令行](./cli.md)中指定它们。

### 新会话从哪里开始

`new-session-directory` 设置决定新会话所在的文件夹：

- `current`（默认）：你当前所在会话的目录
- `project`：项目的根目录
- `home`：你的主目录

<a id="how-an-unnamed-session-is-named"></a>
### 未命名的会话如何命名

在你或智能体为会话命名之前，`session-name` 设置（设置中的 **会话名称取自**）决定边栏显示什么：

- `focused`（默认）：你所在窗格中程序的标题。如果该窗格只运行着 shell，则改用最需要你处理的那个窗格。
- `lead`：最需要你处理的窗格中程序的标题，比如正在工作或在等你的智能体
- `folder`：第一个窗格所在的文件夹，不论其中运行着什么

## 项目

**项目**就是一个文件夹。Kero 在边栏中将会话归到各自的项目下。用 <kbd>⌘</kbd> <kbd>O</kbd> 打开项目，或者让 `kero new` 根据会话的启动目录自动选择。

```sh
kero projects            # 列出项目
kero new -p my-app       # 按名称在某个项目中新建会话
```

## kerod

会话运行在 **kerod** 中，这是一个由 app 按需启动的守护进程。Kero 只是 kerod 的一扇窗口：

- 退出 Kero 后，所有会话仍在运行。
- 再次打开 Kero，所有会话都保持原样，回滚缓冲也在。
- kerod 自身重启之后（比如重启电脑后），Kero 会在原来的目录中重新启动你的会话。设置 `restore-sessions = false` 可以关闭这一行为。
- 为某个智能体设置好 [Kero 的技能](./agents.md#install-the-skill)后，原先运行 Claude Code、Codex、Pi 或 OpenCode 的窗格会接着之前的对话继续，效果与智能体自带的恢复选项相同。其他程序不会擅自重新启动：它们的窗格会回到 shell。设置 `resume-agents = false` 可以关闭这一行为。

```sh
kero daemon status       # kerod 是否在运行？
kero daemon restart      # 重启它（会话会重新启动）
kero daemon stop         # 停止它，并结束所有会话
```

### 退出

退出 Kero 后，会话继续运行，再次打开时原样呈现。若希望退出时一并结束它们（与**退出并结束所有会话**相同），请设置 `quit-ends-sessions = true`：此后无论是点关闭按钮、按 ⌘Q 还是使用菜单，退出都会结束本机的全部会话及其中的程序，并停止 kerod；有程序在运行时，会按 `confirm-close` 的设置先确认。其他机器上的会话继续运行。

```ini
quit-ends-sessions = true
```
