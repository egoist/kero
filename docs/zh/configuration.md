---
title: 配置
description: Kero 的配置文件、配置项及其默认值。
---

# 配置

Kero 把所有设置放在一个纯文本文件里。设置窗口（<kbd>⌘</kbd> <kbd>,</kbd>）会替你修改它，并保留你的注释和顺序；你手动编辑后，Kero 也会自动重新加载。

## 配置文件

Kero 按以下优先顺序读取：

1. `$KERO_CONFIG`
2. `$XDG_CONFIG_HOME/kero/config`
3. `~/.config/kero/config`

它采用 Ghostty 的语法：每行一个 `key = value`，`#` 开头为注释，列表类的配置项写成多行重复。凡是含义与 Ghostty 相同的配置项，都沿用 Ghostty 的名字。

```ini
# ~/.config/kero/config
font-size = 14
theme = light:GitHub Light Default,dark:Catppuccin Mocha
cursor-style = bar

env = EDITOR=nvim
env = HOMEBREW_NO_AUTO_UPDATE=1

keybind = cmd+shift+d=pane.split.down
```

文件里只需写你要改的项，其余都保持默认。

```sh
kero config edit              # 在 $EDITOR 中打开
kero config show              # 列出所有配置项及其当前值
kero config check             # 报告未知的配置项和无效的值
```

## 通用

| 配置项                  | 默认值    | 说明                                                          |
| ----------------------- | --------- | ------------------------------------------------------------- |
| `new-session-directory` | `current` | 新会话的起始目录：`current`、`project` 或 `home`               |
| `session-name`          | `focused` | 未手动命名的会话如何取名：`focused`、`lead` 或 `folder`（[详情](./sessions.md#how-an-unnamed-session-is-named)） |
| `focus-follows-mouse`   | `false`   | 指针移入哪个窗格，就聚焦哪个窗格                              |
| `confirm-close`         | `true`    | 关闭仍有程序在运行的窗格前先确认                              |
| `restore-sessions`      | `true`    | kerod 重启后（例如开机后）重新启动之前的会话                   |
| `resume-agents`         | `true`    | 会话重新启动时，恢复每个窗格中智能体的对话                    |
| `macos-show-app-icon`   | `dock-and-menubar` | 在 macOS 上显示 Kero 图标的位置：`dock-and-menubar`、`dock` 或 `menubar`。图标显示在菜单栏时，关闭窗口后 Kero 会继续在那里运行。Windows 和 Linux 上始终显示在通知区域，关闭窗口后同样会继续运行 |

## 外观

| 配置项               | 默认值   | 说明                                                            |
| -------------------- | -------- | --------------------------------------------------------------- |
| `window-theme`       | `system` | 应用外观：`system`、`light` 或 `dark`                            |
| `language`           | `system` | 应用语言：`system`、`en`、`ja` 或 `zh-Hans`                      |
| `background`         | `petal`  | 窗口底色：`petal`、`mist`、`meadow`、`dusk` 或 `plain`           |
| `window-translucent` | `true`   | 让桌面透过窗口显示出来                                          |

## 终端

| 配置项                | 默认值  | 说明                                                                     |
| --------------------- | ------- | ------------------------------------------------------------------------ |
| `theme`               | `kero`  | 终端配色：`kero`、任意 Ghostty 主题，或 `light:<theme>,dark:<theme>`      |
| `font-family`         |         | 留空则使用 Kero 自带的 JetBrains Mono Nerd Font；设为 `monospace` 则使用系统等宽字体；也可以填任何已安装的字体族 |
| `font-size`           | `13`    | 单位为磅                                                                 |
| `font-weight`         | `400`   | `100` 到 `900`                                                           |
| `line-height`         | `1.22`  | 字体默认行高的倍数                                                       |
| `font-ligatures`      | `true`  | 按字体的设计连写字符                                                     |
| `font-thicken`        | `false` | 加粗笔画，同 Ghostty                                                     |
| `minimum-contrast`    | `3`     | 文字与背景之间保持的最低对比度，从 `1`（不限制）到 `21`，让为深色背景设计的颜色在浅色背景上也清晰可读，同 Ghostty |
| `dim-unfocused-terminals` | `true` | 会话有多个窗格时，淡化未聚焦的终端                                  |
| `cursor-style`        | `block` | `block`、`bar` 或 `underline`；程序可以更改它                            |
| `cursor-style-blink`  | `true`  | 光标闪烁                                                                 |
| `macos-option-as-alt` | `false` | Option 键向程序发送 Alt（Meta）                                          |
| `copy-on-select`      | `false` | 选中内容即复制到剪贴板                                                   |
| `clipboard-read`      | `ask`   | 程序读取剪贴板（OSC 52）时：`ask`、`allow` 或 `deny`                     |
| `right-click-action`  | `context-menu` | `context-menu`、`paste` 或 `copy-or-paste`                        |

## Shell

| 配置项             | 默认值  | 说明                                                           |
| ------------------ | ------- | -------------------------------------------------------------- |
| `command`          |         | 新窗格使用的 shell；留空则使用你的登录 shell                    |
| `env`              |         | 以 `NAME=value` 形式加入每个窗格的环境变量；可重复多行          |
| `scrollback-limit` | `4`     | 每个窗格保留的回滚缓冲大小，单位 MB；`0` 表示不保留             |

## 通知

| 配置项              | 默认值  | 说明                                           |
| ------------------- | ------- | ---------------------------------------------- |
| `notify-on-waiting` | `true`  | 会话需要你时                                   |
| `notify-on-done`    | `true`  | 智能体完成时                                   |
| `notify-on-error`   | `true`  | 程序报告失败时                                 |
| `notify-sound`      | `false` | 通知时播放提示音                               |
| `dock-badge`        | `true`  | 在 Dock 图标上显示有多少会话需要你             |
| `dock-bounce`       | `false` | 有会话开始需要你时，Dock 图标跳动一次          |

## 智能体

| 配置项           | 默认值  | 说明                                                |
| ---------------- | ------- | --------------------------------------------------- |
| `remote-control` | `true`  | 允许 `kero do` 和 `kero focus` 操控应用             |

## 主机

应用会显示这些机器上的会话，`kero -H` 也能连到它们。参见[远程主机](./remote.md)。

| 配置项         | 默认值  | 说明 |
| -------------- | ------- | ---- |
| `host`         |         | 一台主机，写作 `name=address`：通过 SSH 连接时用 `me@devbox` 或 `ssh://…`，WSL 用 `wsl://distro`，kerod 的 tailnet 监听地址用 `http(s)://…`。在后面加上 ` remote-control` 可允许它的程序操控应用，加上 ` color=teal`（red、orange、amber、green、teal、blue、purple 或 pink）可为它的会话标色。每台主机写一行 |
| `listen`       |         | 允许其他机器上的 Kero 连接本机：`tailnet://:7373` 监听本机的 Tailscale 地址，`tailnet-serve://` 使用 Tailscale Serve。每个地址写一行 |
| `listen-allow` |         | 除本机所有者外还允许谁连接：某个 tailnet 登录账号、`tag:name`，或用 `*` 允许 tailnet 上的所有人。每项写一行 |
| `remote-updates` | `false` | 允许你其他机器上的 Kero 把这里的 Kero 应用更新到它的版本，应用会随之重新启动 |

## Git

| 配置项        | 默认值  | 说明                                                                                              |
| ------------- | ------- | ------------------------------------------------------------------------------------------------- |
| `git-status`  | `true`  | 显示每个会话的分支和[改动](./changes.md)                                                          |
| `diff-layout` | `auto`  | 改动面板中的 diff 布局：`unified`、`split`（左右对照）或 `auto`（面板够宽时左右对照）             |

<a id="browser"></a>

## 浏览器

| 配置项                | 默认值                     | 说明                                                                                |
| --------------------- | -------------------------- | ----------------------------------------------------------------------------------- |
| `browser-block-ads`   | `true`                     | 在浏览器窗格中[拦截广告和跟踪器](./panes.md#blocking-ads)                            |
| `browser-filter-list` | `easylist`、`easyprivacy`  | 用于拦截的过滤列表。每个列表写一行；留空则不使用任何列表                            |

`browser-filter-list` 可以填 Kero 内置列表的名称，也可以填任意 Adblock Plus 语法列表的 `https://` URL：

| 名称               | 列表                                                                |
| ------------------ | ------------------------------------------------------------------- |
| `easylist`         | EasyList：广告                                                      |
| `easyprivacy`      | EasyPrivacy：跟踪器和统计分析                                       |
| `peter-lowe`       | Peter Lowe 列表：广告和跟踪服务器                                   |
| `easylist-china`   | EasyList China：中文网站上的广告                                    |
| `fanboy-cookie`    | EasyList Cookie List：Cookie 提示和同意横幅                         |
| `fanboy-social`    | Fanboy's Social Blocking List：社交媒体按钮和嵌入内容               |
| `fanboy-annoyance` | Fanboy's Annoyance List：弹窗和提示，并包含上面两个列表             |

```ini
browser-filter-list = easylist
browser-filter-list = easyprivacy
browser-filter-list = fanboy-cookie
browser-filter-list = https://example.com/my-filters.txt
```

<a id="keyboard"></a>

## 键盘

`keybind` 用于重新绑定操作，格式为 `<keys>=<action>`。每个绑定写一行。把操作设为 `unbind` 即可释放对应按键。

```ini
keybind = cmd+shift+d=pane.split.down
keybind = cmd+k=palette.open
keybind = cmd+b=unbind
```

运行 `kero actions` 查看所有操作 id，默认快捷键见[键盘快捷键](./shortcuts.md)。
