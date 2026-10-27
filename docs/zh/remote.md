---
title: 远程主机
description: 在 Linux 机器、云虚拟机或另一台电脑上运行会话，并在同一个边栏中与本地会话一起查看。
---

# 远程主机

Kero 可以在同一个窗口中显示运行在其他机器上的会话，比如 Linux 开发机、云虚拟机、桌下的 Mac mini 或某个 WSL 发行版，与本地会话放在一起。它们共享同样的边栏、状态、通知和 `kero` 命令。每台机器运行各自的 kerod，因此合上笔记本或退出 Kero 后，远程智能体仍会继续运行，与本地一样。

## 快速开始

任何装有 Kero 的机器都可以作为主机。它可以是你已经在用 Kero 应用的另一台电脑，也可以是没有显示器的服务器。

### 装有 Kero 应用的电脑

应用本身无需额外安装任何东西：它自带的 kerod 就能充当主机。选择其他机器连接它的方式：

- **通过 Tailscale。** 在主机上的应用中，打开 **设置 › 主机 › 允许其他机器连接**。界面会显示可在其他机器上添加的地址，例如 `http://studio.tail1234.ts.net:7373`。详见 [Tailscale](#tailscale)。
- **通过 SSH。** 如果这台电脑接受 SSH 登录（在 Mac 上为 **系统设置 › 通用 › 共享 › 远程登录**），就用你传给 `ssh` 的地址添加它。Kero 会自动找到那台电脑上的应用。

即使主机上的应用已关闭，其中的会话仍会继续运行，和在你自己电脑上一样。

### 服务器

在 Linux 机器、云虚拟机或任何没有安装应用的机器上，安装 Kero 的服务器版本。它不需要 root 或管理员权限，也不需要显示器和 GTK。在 Linux 或 macOS 上：

```sh
curl -fsSL https://github.com/egoist/kero/releases/latest/download/install-server.sh | sh
```

在 Windows 上，于 PowerShell 中运行：

```powershell
irm https://github.com/egoist/kero/releases/latest/download/install-server.ps1 | iex
```

### 添加主机

在你的电脑上打开 **设置 › 主机**，输入主机地址（例如 SSH 用的 `me@devbox`，或主机上应用显示的地址），然后点击 **添加**。主机上的项目会和你自己的项目一起出现在边栏中，并各自标注主机名。

命令行中的等效操作：

```sh
kero hosts add devbox me@devbox
kero -H devbox new -n review -- claude
```

::: tip
如果添加的主机上没有安装 Kero，边栏会给出提示并提供 **安装 Kero…**，它会通过 SSH 在主机上运行上面的安装脚本。
:::

## Kero 如何连接主机

地址决定了如何连接一台主机。无论在设置中、配置文件中，还是 `kero -H` 之后，Kero 接受的地址格式都相同。

| 地址 | 方式 |
| --- | --- |
| `devbox`、`me@devbox`、`me@devbox:2222`、`ssh://me@devbox` | SSH，使用你的 `~/.ssh/config`、密钥和 agent |
| `wsl://Ubuntu`、`wsl://` | 本台 Windows 电脑上的 WSL 发行版，通过 `wsl.exe` 连接 |
| `http://devbox:7373` | kerod 在 tailnet 地址上的监听（见 [Tailscale](#tailscale)） |
| `https://devbox.tail1234.ts.net` | 位于 Tailscale Serve 之后的 kerod |

Kero 为每台主机只建立一条连接，所有内容都经由它传输：边栏状态、你查看的每个窗格，以及命令行发出的命令。连接经过压缩，并通过心跳在几秒内发现断线。连接中断时（例如笔记本休眠），该主机的会话会以淡化样式留在边栏中，Kero 会自动重连，重试间隔逐渐拉长，最长一分钟。

### SSH

通过 SSH 连接时，Kero 会在主机上运行 `kero __bridge`：如果 kerod 尚未运行，它会先启动 kerod，再把连接转交给它。除了 Kero 本身（应用或服务器版本）之外，主机上无需任何设置，也不会有任何程序监听网络。

Kero 通过 SSH 连接时从不弹出任何提示，因为应用里没有人可以回应：

- **带口令的密钥**需要借助你的 SSH agent。和终端里的 `ssh` 一样，Kero 使用你的 shell 在 `SSH_AUTH_SOCK` 中设置的 agent，例如 1Password 的。
- **首次连接的主机**需要先信任其密钥。在终端中运行一次 `ssh me@devbox` 即可。
- **不支持密码登录。** 请使用密钥。

Kero 会在主机的以下位置查找 `kero`：`~/.local/bin`（Windows 上为 `%LOCALAPPDATA%\Programs\kero-server`）、桌面应用及其命令行工具，以及你的 `PATH`。如果装在别处，请在地址中指定：`me@devbox?kero=/opt/kero/kero`，Windows 上则为 `me@pc?kero=C:/kero/kero.exe`。

### Windows 主机

Kero 通过 SSH 连接 Windows 机器，因此需要先以管理员身份开启其 OpenSSH 服务器（**设置 › 系统 › 可选功能**）。Kero 支持该服务器的默认 shell cmd，也支持 PowerShell。首次连接时它会检测使用的是哪一种，因此那次连接会稍慢一些。

安装脚本会在任务计划程序中以你的身份创建一个任务来运行 kerod，在你登录这台机器时于你的会话中启动它。当没有人登录时，kerod 会在 Kero 连接时启动，并在连接结束后继续运行。以这种方式启动的 kerod 不持有你的 Windows 密码（这与使用密钥通过 SSH 运行的程序一样），因此其会话中的程序无法访问网络共享，也无法使用 Windows 为你保存的凭据。登录一次这台机器，或在登录后重启 kerod，即可让它们以你的完整账户权限运行。

### WSL

在 Windows 上，`wsl://Ubuntu` 会连接安装在该 WSL 发行版中的 Kero，效果与 SSH 相同。`wsl://` 表示默认发行版。如果其中尚未安装 Kero，Kero 会提议为你安装，与 SSH 时一样。

在最后一个从 Windows 启动的程序结束一段时间后，WSL 可能会停止该发行版，kerod 也随之停止。要让智能体持续运行，就得让发行版保持运行，例如[启用 systemd](https://learn.microsoft.com/windows/wsl/systemd)，并在其中运行 `kero daemon install-service`。

<a id="tailscale"></a>

### Tailscale

kerod 也可以在你的 tailnet 上监听，这样就完全不需要 SSH。Tailscale 会告诉 kerod 连接者是谁，默认只有拥有这台机器的 Tailscale 用户才能连入。在装有应用的主机上，打开 **设置 › 主机 › 允许其他机器连接**，界面会显示可在其他机器上添加的地址。在服务器上，或者想手动设置时，在主机的配置中加入：

```ini
# 主机上的 ~/.config/kero/config
listen = tailnet://:7373
```

然后以 `http://devbox:7373` 添加该主机。连接本身是明文 HTTP，由 WireGuard 在 tailnet 设备之间加密。

如果想改用 Tailscale 的证书通过 HTTPS 提供服务，可以让 kerod 监听一个套接字，再将 Tailscale Serve 指向它：

```ini
listen = tailnet-serve://
```

```sh
tailscale serve --bg --https=443 unix:$HOME/.config/kero/serve.sock
```

然后以 `https://devbox.tail1234.ts.net` 添加该主机。套接字是 Kero 数据文件夹中的 `serve.sock`：Linux 上为 `~/.config/kero`，macOS 上为 `~/Library/Application Support/kero`。

要允许所有者以外的人连入，用 `listen-allow` 列出他们：可以是 tailnet 登录名、表示带标签设备的 `tag:ci`，或表示 tailnet 上任何人的 `*`。带标签的机器没有所有者，因此只有 `listen-allow` 能让人连入。Tailscale Serve 不会告诉 kerod 带标签设备的身份：它们需要连接 `tailnet://` 监听。

```ini
listen-allow = alice@example.com
listen-allow = tag:ci
```

`listen` 和 `listen-allow` 变化时，kerod 会随之调整；关闭某个监听时，经由它建立的连接也会断开。kerod 运行期间新增的 `tailnet-serve://` 监听要等到 `kero daemon restart` 后才生效。只有配置要求时 kerod 才会监听，而且只在 Tailscale 上监听。它会拒绝来自网页浏览器的请求，因此你访问的网页无法连到它。来自互联网的 Funnel 请求也永远无法进入。要让它随机器一起持续监听，请将其作为服务运行（见下文）。

## 将 kerod 作为服务运行

在装有应用的主机上，kerod 会在应用打开时或 Kero 通过 SSH 连接时启动。在服务器上，请把 kerod 作为你自己的服务运行，让它随机器启动，并在无人登录时保持会话运行。安装脚本会替你完成这一步。在 Mac 上，该服务是一个 launchd agent，只在你登录 Mac 期间运行，所以请在那台 Mac 上保持登录；脚本会在你已登录时安装它。在 Windows 上，它是任务计划程序中的一个任务，在你登录时启动 kerod。

```sh
kero daemon install-service      # Linux 上为 systemd 用户单元，macOS 上为 launchd agent，Windows 上为计划任务
kero daemon status               # 运行方式及监听位置
kero daemon uninstall-service
```

在 Linux 上，这会先启用 lingering（`loginctl enable-linger`），使你的服务在登出后继续运行。没有它，服务会在你最后一个 SSH 会话结束时停止——而按需启动的 kerod 反倒不会——所以没有 lingering 时 `install-service` 会拒绝继续。如果你的系统需要管理员才能启用 lingering，请让管理员运行 `sudo loginctl enable-linger <you>`，或者加上 `--no-linger` 强行安装服务。

`kero daemon serve` 会在前台运行 kerod，并将日志输出到标准错误，供你自己的服务管理器使用。它不会因空闲而退出。`--listen` 会取代配置中的 `listen` 项。

## 在主机上工作

- **边栏。** 边栏列出所有项目：先是你自己的，然后按 **设置 › 主机** 中的顺序列出各主机的项目。主机的项目会在名称后带上主机名，如 `api` `devbox`，这样两台机器上的同一个仓库会并排显示。只有在需要你处理时，主机才会单独占一行：Kero 无法连接它、它需要更新，或其上尚未安装 Kero。没有会话的主机不会显示；可以用“打开项目”在其上启动一个会话。右键点击主机的某个项目，即可打开该主机的菜单：重新连接、重启 kerod、更新 Kero、设置颜色、打开其设置。
- **颜色。** 每台主机都有一种颜色，根据主机名选定：它在边栏中的标签和窗格标题栏中的主机名都会使用这种颜色，让远程窗格一眼就能认出。可以在主机菜单的 **颜色** 中另选，或在地址后加上 `color=`（`host = devbox=me@devbox color=teal`）。
- **新建会话。** <kbd>⌘</kbd> <kbd>T</kbd> 和 **新建会话** 会在你当前查看的会话所在的主机上启动会话。项目的 **+** 会在该项目中、在其所在机器上启动会话。
- **打开项目。** 添加主机后，<kbd>⌘</kbd> <kbd>O</kbd> 会在 Kero 内列出文件夹，而不是弹出系统对话框，起始位置是你当前查看的会话所在的机器；顶部的切换器可以列出其他机器的文件夹。输入文字可筛选，也可以输入 `~/code` 这样的路径。<kbd>↩</kbd> 进入文件夹，<kbd>⌘</kbd> <kbd>↩</kbd> 或 **打开** 则将其作为项目打开。
- **路径。** 在远程窗格中按住 <kbd>⌘</kbd> 点击文件路径，会在下方的窗格中用主机的 `$EDITOR` 打开该文件。文件夹则会在那台主机上的新会话中打开。Kero 绝不会打开你电脑上恰好同路径的文件。按住 <kbd>⌘</kbd> 悬停在图片路径上，可以预览主机上的图片。
- **粘贴图片和文件。** 将图片或文件粘贴到远程窗格时，它们会被复制到主机上的一个私有临时文件夹，并在那里粘贴其路径，因此读取图片路径的智能体（例如 Claude Code）可以照常工作。将文件拖到远程窗格上，粘贴的仍是你电脑上的路径。
- **智能体。** 在远程窗格中，`kero` 与该主机的 kerod 通信，因此智能体技能在那里无需改动即可使用。在主机上运行 `kero skill setup` 即可。
- **通知。** 主机的通知和窗口标题都会带上主机名，远程程序无法冒充本地程序。

### 远程控制

`kero focus` 和 `kero do` 让程序可以操控应用。对主机而言，这意味着另一台机器上的代码在操控你电脑的窗口，因此默认关闭。可以在 **设置 › 主机** 中按主机开启，或在地址后加上 `remote-control`：

```ini
host = devbox=me@devbox remote-control
```

### 设置

外观、键盘和通知属于应用的设置。主机的 shell、`env`、回滚缓冲和会话恢复则来自该主机上的配置，因为 kerod 在那里读取它们。在主机上运行 `kero config edit` 即可修改。

## 版本与更新

应用和主机可以运行不同版本的 Kero。当主机运行的版本比应用旧时，它在边栏中的第一个项目会显示 **更新**。点击后，Kero 会把与应用相同版本的 Kero 下载到主机上，用 Kero 自身更新所用的签名密钥，针对该版本和平台进行校验，然后在那里重启 kerod。重启后，主机的会话会恢复到原来的位置并保留历史，但其中正在运行的程序会结束，因此 Kero 会先征求你的确认。

- Kero 只在你要求时更新主机，绝不会在重连时自动更新，也绝不会降级到更旧的版本。
- 当主机运行的 Kero 比应用新时，请改为更新应用（**设置 › 通用**）。
- Kero 会更新通过其安装脚本安装的版本。如果你在主机上用其他方式安装了 Kero，请按你安装时的方式更新。
- 运行 Kero 桌面应用的主机，在你允许后即可接受来自其他机器的更新：在那台电脑上打开 **设置 › 主机 › 允许它们更新这里的 Kero**（`remote-updates = true`）。之后那里的应用会更新到最新版本、重新启动，并重启 kerod。在此之前，请在那台电脑上更新。

通过命令行：

```sh
kero -H devbox version           # 本机 kero 的版本，以及主机的版本
kero -H devbox daemon status
kero -H devbox daemon update     # 更新到本机 kero 的版本
kero -H devbox daemon restart
kero daemon update               # 在主机上运行，更新到最新版本
kero daemon update 2.1.0         # 在主机上运行，更新到指定版本，也可以是旧版本
```

## 命令行

在命令之前加上 `-H`（或 `--host`），可让操作会话的命令指向某台主机的 kerod。它接受主机名、地址，或表示本机的 `local`。`$KERO_HOST` 作用相同，但在窗格内除外——在那里 `kero` 作用于窗格自身所在的机器。仅针对本机的命令，例如 `kero config` 和 `kero hook`，会忽略 `$KERO_HOST`。

```sh
kero hosts                       # 你添加的主机（--json 输出 JSON）
kero hosts add build ci@build.lab --remote-control
kero hosts check build           # 连接并报告结果；可用名称或地址
kero hosts install build         # 通过 SSH 或 WSL 在那里安装 Kero
kero hosts remove build
kero -H build ls
kero -H build prompt review "run the tests and fix them"
kero clients                     # 当前连接到本机 kerod 的客户端
```

应用和命令行共用一份主机列表，即配置中的 `host` 项：

```ini
host = devbox=me@devbox
host = build=ssh://ci@build.lab:2222 remote-control
host = ubuntu=wsl://Ubuntu
```

| 变量 | 作用 |
| --- | --- |
| `KERO_HOST` | 命令作用的主机，同 `-H` |
| `KERO_SSH` | Kero 运行的 `ssh` 程序，取代 `PATH` 中的那个 |
| `KERO_RELEASES` | Kero 发布版本的镜像，供安装脚本和 `kero daemon update` 使用 |

## 安全

- **一条连接能做其账户能做的任何事，** 包括启动程序，与本地连接一样。通过 SSH 时，它就是你自己的账户，因为 SSH 以你的身份登录。通过 Tailscale 时，只有机器所有者允许的人才能连入。
- **套接字只属于你。** kerod 的套接字创建时仅其所属用户可读，kerod 也会拒绝来自其他用户进程的连接。
- **更新经过签名。** 服务器版本只会用 Kero 发布密钥签名的归档包更新自身。
- `kero clients` 会列出连接到某个 kerod 的客户端及其连接方式：`uid 501 over unix`、`me from 10.0.0.5 over ssh`、`alice@example.com over tailnet`。

## 限制

- 服务器版本支持 Linux（glibc 2.28 或更高版本）、macOS 以及 Windows 10（1809）或更高版本，架构为 x86-64 和 ARM64。装有 Kero 应用的机器不需要服务器版本。
- 将文件拖到远程窗格上，粘贴的是你电脑上的路径。请改用粘贴。
- 一台主机对应一个账户。登录服务器（多人在同一台机器上访问各自的账户）的支持已在计划中。
