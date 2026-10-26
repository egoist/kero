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
| 恢复对话…                  | <kbd>⌘</kbd> <kbd>⇧</kbd> <kbd>O</kbd>       |
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

<a id="past-conversations"></a>

## 过去的对话

为智能体设置好 [Kero 的技能](./agents.md#install-the-skill)后，Kero 会记住在它的窗格中运行过的 Claude Code、Codex、Pi 和 OpenCode 对话，这样即使会话已经关闭，你也能接着继续。

- <kbd>⌘</kbd> <kbd>P</kbd> 在**最近的对话**下列出最近几个，输入时也能找到更早的。
- **会话 › 恢复对话…**（<kbd>⌘</kbd> <kbd>⇧</kbd> <kbd>O</kbd>）列出全部。

选中一个，Kero 会在它当初运行的目录和项目中、用当时会话的名字启动一个会话，并像智能体自带的恢复选项那样接着对话。如果某个窗格仍在运行这个对话，则会跳到那个窗格。对话以会话的名字显示，没有名字时显示标题：Claude Code 自己的标题，或智能体显示为窗格标题的内容。

kerod 在状态文件旁的 `conversations.json` 中保留最近 200 个对话，每台主机各自保留自己的。

```sh
kero history             # 所有对话，最近运行的在前
kero history login       # 与 “login” 匹配的对话
kero resume 13b9         # 用 ID、ID 的前缀或名字恢复
```

<a id="ended-sessions"></a>

### 在侧边栏中

在“设置 › 通用 › **会话历史**”中开启，或设置 `session-history = true`，侧边栏底部也会列出它们。**已结束**按从新到旧列出当前没有窗格在运行的对话：先显示最新的 5 个，然后是**显示全部**。其他主机的对话也在其中，带有主机名标签。点击标题即可展开。

- 点击其中一个即可恢复，与命令面板相同。
- 悬停并点击归档按钮，它会移到下方的**已归档**，在那里仍可恢复。再次运行时它会离开已归档。
- 右键点击其中一个，可以恢复、归档或还原它，复制它的 ID 或文件夹，显示文件夹，或删除它（只是让 Kero 忘记）。右键点击**已结束**可全部归档，右键点击**已归档**可全部删除。
