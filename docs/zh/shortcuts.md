---
title: 键盘快捷键
description: Kero 的默认键盘快捷键，以及用于重新绑定的操作 id。
---

# 键盘快捷键

以下任意快捷键都可以在 **设置 › 键盘** 中重新绑定，也可以在[配置文件](./configuration.md#keyboard)中用 `keybind` 修改。

在 Windows 和 Linux 上，<kbd>Ctrl</kbd> 加字母的组合归 shell 使用（<kbd>Ctrl</kbd> <kbd>D</kbd>、<kbd>Ctrl</kbd> <kbd>R</kbd>、<kbd>Ctrl</kbd> <kbd>W</kbd>……），因此 Kero 的快捷键会像 Windows Terminal 一样额外加上 <kbd>Shift</kbd>，或改用 <kbd>Alt</kbd>。短横线表示该操作在对应平台上没有快捷键。

## Kero

| 操作                         | macOS                                  | Windows 和 Linux                              | 操作 id          |
| ---------------------------- | -------------------------------------- | --------------------------------------------- | ---------------- |
| 设置…                        | <kbd>⌘</kbd> <kbd>,</kbd>              | <kbd>Ctrl</kbd> <kbd>,</kbd>                  | `settings.open`  |
| 退出（会话继续运行）         | <kbd>⌘</kbd> <kbd>Q</kbd>              | <kbd>Ctrl</kbd> <kbd>Shift</kbd> <kbd>Q</kbd> |                  |
| 退出并结束所有会话…          | <kbd>⌘</kbd> <kbd>⌥</kbd> <kbd>Q</kbd> | –                                             | `app.quitAll`    |

## 会话

| 操作                        | macOS                                  | Windows 和 Linux                              | 操作 id             |
| --------------------------- | -------------------------------------- | --------------------------------------------- | ------------------- |
| 新建会话                    | <kbd>⌘</kbd> <kbd>T</kbd>              | <kbd>Ctrl</kbd> <kbd>Shift</kbd> <kbd>T</kbd> | `session.new`       |
| 在主目录新建会话            | <kbd>⌘</kbd> <kbd>⇧</kbd> <kbd>T</kbd> | –                                             | `session.newHome`   |
| 在工作树中新建会话…         | <kbd>⌘</kbd> <kbd>⌥</kbd> <kbd>T</kbd> | –                                             | `session.newWorktree` |
| 打开项目…                   | <kbd>⌘</kbd> <kbd>O</kbd>              | <kbd>Ctrl</kbd> <kbd>Shift</kbd> <kbd>O</kbd> | `project.open`      |
| 前往会话…                   | <kbd>⌘</kbd> <kbd>P</kbd>              | <kbd>Ctrl</kbd> <kbd>Shift</kbd> <kbd>P</kbd> | `palette.open`      |
| 恢复对话…                   | <kbd>⌘</kbd> <kbd>⇧</kbd> <kbd>O</kbd> | –                                             | `conversation.resume` |
| 跳到需要你的会话            | <kbd>⌘</kbd> <kbd>J</kbd>              | <kbd>Ctrl</kbd> <kbd>Shift</kbd> <kbd>J</kbd> | `session.attention` |
| 下一个会话                  | <kbd>⌘</kbd> <kbd>⇧</kbd> <kbd>]</kbd> | <kbd>Ctrl</kbd> <kbd>PgDn</kbd>               | `session.next`      |
| 上一个会话                  | <kbd>⌘</kbd> <kbd>⇧</kbd> <kbd>[</kbd> | <kbd>Ctrl</kbd> <kbd>PgUp</kbd>               | `session.previous`  |
| 重命名会话                  | <kbd>⌘</kbd> <kbd>R</kbd>              | –                                             | `session.rename`    |
| 重启窗格                    | <kbd>⌘</kbd> <kbd>⇧</kbd> <kbd>R</kbd> | <kbd>Ctrl</kbd> <kbd>Shift</kbd> <kbd>R</kbd> | `pane.restart`      |
| 关闭                        | <kbd>⌘</kbd> <kbd>W</kbd>              | <kbd>Ctrl</kbd> <kbd>Shift</kbd> <kbd>W</kbd> | `pane.close`        |
| 关闭会话                    | <kbd>⌘</kbd> <kbd>⇧</kbd> <kbd>W</kbd> | –                                             | `session.close`     |

<kbd>⌘</kbd> <kbd>1</kbd>–<kbd>9</kbd>（Windows 和 Linux 上为 <kbd>Ctrl</kbd> <kbd>1</kbd>–<kbd>9</kbd>）跳到边栏中对应的会话，<kbd>Ctrl</kbd> <kbd>Tab</kbd> 跳到下一个会话。

## 窗格

| 操作          | macOS                                  | Windows 和 Linux                                  | 操作 id            |
| ------------- | -------------------------------------- | ------------------------------------------------- | ------------------ |
| 向右拆分      | <kbd>⌘</kbd> <kbd>D</kbd>              | <kbd>Alt</kbd> <kbd>Shift</kbd> <kbd>=</kbd>      | `pane.split.right` |
| 向下拆分      | <kbd>⌘</kbd> <kbd>⇧</kbd> <kbd>D</kbd> | <kbd>Alt</kbd> <kbd>Shift</kbd> <kbd>-</kbd>      | `pane.split.down`  |
| 新建浏览器面板 | <kbd>⌘</kbd> <kbd>⇧</kbd> <kbd>B</kbd> | <kbd>Alt</kbd> <kbd>Shift</kbd> <kbd>B</kbd>     | `pane.browser`     |
| 打开位置      | <kbd>⌘</kbd> <kbd>L</kbd>              | –                                                 | `browser.address`  |
| 放大窗格      | <kbd>⌘</kbd> <kbd>⇧</kbd> <kbd>↩</kbd> | <kbd>Ctrl</kbd> <kbd>Shift</kbd> <kbd>Enter</kbd> | `pane.zoom`        |
| 下一个窗格    | <kbd>⌘</kbd> <kbd>]</kbd>              | <kbd>Ctrl</kbd> <kbd>Shift</kbd> <kbd>]</kbd>     | `pane.next`        |
| 上一个窗格    | <kbd>⌘</kbd> <kbd>[</kbd>              | <kbd>Ctrl</kbd> <kbd>Shift</kbd> <kbd>[</kbd>     | `pane.previous`    |
| 左侧窗格      | <kbd>⌘</kbd> <kbd>⌥</kbd> <kbd>←</kbd> | <kbd>Alt</kbd> <kbd>←</kbd>                       | `pane.left`        |
| 右侧窗格      | <kbd>⌘</kbd> <kbd>⌥</kbd> <kbd>→</kbd> | <kbd>Alt</kbd> <kbd>→</kbd>                       | `pane.right`       |
| 上方窗格      | <kbd>⌘</kbd> <kbd>⌥</kbd> <kbd>↑</kbd> | <kbd>Alt</kbd> <kbd>↑</kbd>                       | `pane.up`          |
| 下方窗格      | <kbd>⌘</kbd> <kbd>⌥</kbd> <kbd>↓</kbd> | <kbd>Alt</kbd> <kbd>↓</kbd>                       | `pane.down`        |

## 显示

| 操作           | macOS                     | Windows 和 Linux                              | 操作 id          |
| -------------- | ------------------------- | --------------------------------------------- | ---------------- |
| 切换边栏       | <kbd>⌘</kbd> <kbd>B</kbd> | <kbd>Ctrl</kbd> <kbd>Shift</kbd> <kbd>B</kbd> | `sidebar.toggle` |
| 切换右侧边栏   | <kbd>⌥</kbd> <kbd>⌘</kbd> <kbd>B</kbd> | –                                             | `rightSidebar.toggle` |
| 显示或隐藏改动 | <kbd>⌥</kbd> <kbd>⌘</kbd> <kbd>G</kbd> | <kbd>Ctrl</kbd> <kbd>Shift</kbd> <kbd>G</kbd> | `changes.toggle` |
| 显示或隐藏文件 | <kbd>⌥</kbd> <kbd>⌘</kbd> <kbd>E</kbd> | <kbd>Ctrl</kbd> <kbd>Shift</kbd> <kbd>E</kbd> | `files.toggle`   |
| 放大           | <kbd>⌘</kbd> <kbd>=</kbd> | <kbd>Ctrl</kbd> <kbd>=</kbd>                  | `text.bigger`    |
| 缩小           | <kbd>⌘</kbd> <kbd>-</kbd> | <kbd>Ctrl</kbd> <kbd>-</kbd>                  | `text.smaller`   |
| 实际大小       | <kbd>⌘</kbd> <kbd>0</kbd> | <kbd>Ctrl</kbd> <kbd>0</kbd>                  | `text.reset`     |
| 快速终端       | –                         | –                                             | `quickTerminal.toggle` |

## 快速终端

快速终端像 Ghostty 的快速终端和 Quake 风格的控制台一样，在任何应用之上从屏幕顶部落下，再按一次快捷键或点击别处时收起。它的快捷键在所有应用中都有效，所以在你于**设置 › 键盘**或[配置文件](./configuration.md#键盘)中指定之前，它没有快捷键：

```ini
keybind = ctrl+`=quickTerminal.toggle
```

它显示一个专属会话“快速终端”，隐藏时和退出 Kero 后都会继续运行，边栏也会和其他会话一起列出它。shell 退出后，下次按下会启动新的 shell。也可以从**显示 › 快速终端**和菜单栏图标的菜单打开它，或用 `kero do quickTerminal.toggle` 在脚本中切换。
