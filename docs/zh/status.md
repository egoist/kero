---
title: 状态与通知
description: Kero 如何跟踪每个窗格在做什么，以及程序如何报告自己的状态。
---

# 状态与通知

Kero 会跟踪每个窗格在做什么，你可以放手让智能体去干活，等有智能体需要你时再回来。

## 窗格状态

每个窗格都有一个状态，显示在边栏中：

| 状态      | 含义                                          |
| --------- | --------------------------------------------- |
| `working` | 程序正忙：智能体在思考，或在运行某个工具      |
| `waiting` | 需要你：有问题要回答，或有权限请求要确认      |
| `idle`    | 没有任何动静，shell 停在提示符处              |
| `error`   | 程序报告自己失败了                            |
| `exited`  | 程序已结束，窗格保留其输出                    |

Kero 根据编程智能体屏幕上显示的内容判断它的状态：它的加载动画、权限请求，或等待你输入的提示符。重绘同样的画面（例如调整窗格大小时）不会改变状态。其他程序在标题显示加载动画时，或在[报告自己的状态](#reporting-status-from-a-program)时，会被视为 `working`。

会话显示其窗格的状态，需要你的会话会被突出显示。按 <kbd>⌘</kbd> <kbd>J</kbd> 跳到下一个需要你的会话。

## 小青蛙 Kero

小青蛙 Kero 会趴在窗口上沿，跟着你的会话：需要你时它会跳，智能体工作时它会一起看，完成时它会欢呼，失败时它会发抖，安静久了就打盹。点它一下，它会眨眼醒来；如果有会话需要你，还会直接带你过去。

窗口上方没有空间时，Kero 会改站在窗口内的底边。沿着窗口边缘拖动它就能换位置；**设置 › 外观 › 小青蛙 Kero** 可以关掉它，配置文件里的 `pet = false` 也一样。

## 通知

当你在看别处时，Kero 会在以下情况通知你：

- 某个会话开始需要你（`notify-on-waiting`）
- 某个智能体完成了（`notify-on-done`）
- 某个程序报告失败（`notify-on-error`）

程序自己发出的桌面通知会像在任何终端中一样显示，且不影响它的状态。

Dock 图标会显示有多少会话需要你（`dock-badge`），也可以在有会话开始需要你时跳动一次（`dock-bounce`）。参见[配置](./configuration.md)。

<a id="reporting-status-from-a-program"></a>

## 从程序报告状态

程序和智能体可以用 `kero report` 告诉 Kero 自己在做什么：

```sh
kero report working "Migrating the database" --progress 40
kero report blocked "Approve the production deploy?" --kind permission
kero report done "Deployed to staging"
kero report clear
```

可用的状态有：

| 状态      | 含义                                                       |
| --------- | ---------------------------------------------------------- |
| `idle`    | 空闲，等待下一条指令                                       |
| `working` | 忙碌中；`--progress` 给出百分比                            |
| `blocked` | 没有你就无法继续；`--kind` 说明它需要什么                  |
| `done`    | 已完成，而你还没看过                                       |
| `error`   | 失败并已停止                                               |
| `clear`   | 不是状态：清除程序之前报告的内容                           |

Kero 会在边栏中显示这条消息。`blocked` 报告会把会话变为*等待中*；你不在时，`done` 和 `blocked` 会通知你。`--kind` 可以是 `permission`（需要批准某件事）、`question`（需要输入回答）或 `auth`（需要登录或令牌）。

`working` 和 `blocked` 只在程序运行期间有效，程序退出即结束。`done` 和 `error` 会一直保留，直到你在该窗格中输入，这样程序在你离开时完成，结果也会留在那里等你查看。被中断的程序应报告 `idle`。

如果只想把窗格标记为需要你，而不改变它的状态：

```sh
kero notify "Need your API key to continue"
```

### 一个窗格中的多个任务

同时执行多项任务的程序可以用 `--id` 分别报告每一项，并用 `--title` 为其命名：

```sh
kero report working "Deploying v2.4.1" --app deploy
kero report working "Pushing image" --id us-east --title "US East" --progress 40
kero report blocked "Approve deploy to production?" --id eu-west --title "EU West" --kind permission
kero report clear --id us-east
```

每次报告都会替换同一 id 下已有的内容，所以每次都要重复 `--app` 和 `--title`。id 可以有子项，例如 `build/test` 是 `build` 的子项；带 id 的 `clear` 会移除该 id 及其所有子项。窗格显示最需要你关注的那条报告，优先级为：`blocked` 高于 `working`，高于 `error`，高于 `done`。

`--app` 是程序的固定名称，例如 `cargo` 或 `terraform`，其下的各个 id 都会沿用它。

### 转义序列

`kero report` 会写出一个 OSC 7501 转义序列，即 [Program Status Protocol](https://www.superlogical.com/rex/docs/build/program-status)，任何程序都可以自己写出它。这不是 Kero 专有的协议：采用它的程序可以向所有支持它的终端报告状态。

```txt
ESC ] 7501 ; state=<state> [:id=<id>] [:kind=<kind>] [:progress=<n>] [:app=<app>] [:title=<base64>] [:msg=<base64>] ESC \
```

字段之间用 `:` 分隔，`msg` 和 `title` 为 Base64 编码的 UTF-8。例如在 shell 中：

```sh
status() {
  printf '\e]7501;state=%s:msg=%s\e\\' "$1" "$(printf '%s' "$2" | base64 | tr -d '\n')"
}
status working "Syncing photos"
rsync -a ~/Photos backup:/photos && status done "Photos synced" || status error "rsync failed"
```

程序可以写出 `ESC ] 7501 ; ? ESC \` 来询问终端是否支持该协议，Kero 会以同样的序列应答。

程序用 ConEmu 的序列 OSC 9;4 显示的进度条不会让它变为 `working`：像 Neovim 这样的编辑器在加载语言服务器时也会显示进度条。Kero 只在判断以这种方式展示工作进度的编程智能体的状态时才读取它。程序应使用 OSC 7501 报告自己的状态。
