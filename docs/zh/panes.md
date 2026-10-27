---
title: 窗格
description: 把会话拆分成多个窗格，并排运行开发服务器、测试或另一个智能体。
---

# 窗格

拆分会话，让多个程序并排运行：左边是智能体，右边是它的开发服务器，下方是测试监视器。

| 操作               | 快捷键                                            |
| ------------------ | ------------------------------------------------- |
| 向右拆分           | <kbd>⌘</kbd> <kbd>D</kbd>                         |
| 向下拆分           | <kbd>⌘</kbd> <kbd>⇧</kbd> <kbd>D</kbd>            |
| 放大窗格           | <kbd>⌘</kbd> <kbd>⇧</kbd> <kbd>↩</kbd>            |
| 下一个 / 上一个窗格 | <kbd>⌘</kbd> <kbd>]</kbd> / <kbd>[</kbd>        |
| 在窗格间移动       | <kbd>⌘</kbd> <kbd>⌥</kbd> <kbd>←</kbd> <kbd>→</kbd> <kbd>↑</kbd> <kbd>↓</kbd> |
| 重启窗格           | <kbd>⌘</kbd> <kbd>⇧</kbd> <kbd>R</kbd>            |
| 关闭窗格           | <kbd>⌘</kbd> <kbd>W</kbd>                         |

**放大**会让一个窗格占满整个会话；再按一次即可恢复其他窗格。

窗格中的程序退出后，窗格会保留下来，方便你查看输出。**重启窗格**会在同一目录下重新启动它的 shell。

## 通过命令行

`kero split` 在另一个窗格旁启动新窗格，并打印其 id：

```sh
kero split --down -- npm run dev
kero split --right --ratio 0.3 -- go test ./... -count=1
```

| 参数                                  | 含义                                           |
| ------------------------------------- | ---------------------------------------------- |
| `--right`（默认）、`--down`、`--left`、`--up` | 新窗格的位置                           |
| `-r`, `--ratio <0..1>`                | 新窗格所占的空间比例（默认 0.5）               |
| `-d`, `--dir <dir>`                   | 在另一个目录中启动                             |
| `-w`, `--wait`                        | 等待其命令结束，并以该命令的状态码退出         |
| `-u`, `--url <url>`                   | 打开浏览器显示该页面，而不是 shell             |

在 Kero 中运行时，`kero split` 会拆分它所在的窗格。在其他地方运行时，需要指定目标：`kero split my-session --down`。

## 浏览器窗格

浏览器窗格在终端旁显示网页：智能体正在开发的开发服务器、它在读的文档、它提交的拉取请求。它和其他窗格一样可以拆分、放大、移动和关闭，Kero 重启后也会回到同一页面。

| 操作             | 快捷键                                 |
| ---------------- | -------------------------------------- |
| 新建浏览器窗格   | <kbd>⌘</kbd> <kbd>⇧</kbd> <kbd>B</kbd> |
| 打开地址         | <kbd>⌘</kbd> <kbd>L</kbd>              |

在地址栏中输入网址，例如 `localhost:3000` 或 `github.com`，或者输入要搜索的词。在命令面板（<kbd>⌘</kbd> <kbd>P</kbd>）中输入的网址也会在新的浏览器窗格中打开。<kbd>⌘</kbd> <kbd>F</kbd> 可在页面中查找文本。

在 shell 中或由智能体用 `--url` 打开：

```sh
kero split --url localhost:5173
kero new --url https://github.com/egoist/kero/pulls
```

之后智能体就能像你一样通过 `kero browser` 使用这个页面：点击、输入、读取文本、等待加载以及截图。参见[命令行](./cli.md#browsing)。

```sh
kero browser type 'input[name=q]' "kero" --enter
kero browser text main
```

<a id="blocking-ads"></a>
### 拦截广告

浏览器窗格使用过滤列表拦截广告和跟踪器，默认为 [EasyList](https://easylist.to) 和 EasyPrivacy，你也可以另选。Kero 会在首次打开浏览器窗格时下载这些列表，并每周更新。在列表就绪前打开的页面，会从列表就绪后的下一次加载起生效。

在**设置 › 浏览器**的**拦截广告**下选择列表：其中还有针对 Cookie 提示、社交按钮、页面干扰元素和中文网站广告的列表。其他网址的列表可以在[配置](./configuration.md#browser)中通过 `browser-filter-list` 添加。列表越多，隐藏的内容越多，偶尔也会导致页面出错。

Kero 能拦截的，就是 WebKit 内容拦截器所能拦截的：发往广告和跟踪服务器的请求，以及列表要隐藏的元素。需要拦截器自身脚本才能实现的过滤规则，例如按文本隐藏元素或改写页面加载内容的规则，不会生效。列表所拦截域名上的页面无法在浏览器窗格中打开。

如需不拦截地浏览，可在**设置 › 浏览器**中关闭**拦截广告**，或在[配置](./configuration.md#browser)中设置 `browser-block-ads = false`。已打开的页面会保留已加载的内容，直到重新加载。
