---
title: 快速开始
description: 安装 Kero，打开项目，启动你的第一个智能体会话。
---

# 快速开始

安装 Kero，打开一个项目，然后在会话中运行你的第一个智能体——即使退出应用，它也会继续运行。

## 安装

从[发布页面](https://github.com/egoist/kero/releases)下载最新版 Kero。在 macOS 上，将 **Kero.app** 拖入“应用程序”文件夹；在 Windows 上，运行 **Kero Setup** 安装程序，无需管理员权限。

在 Windows 上，如果装有 PowerShell 7，会话默认使用它，否则使用 Windows PowerShell；如需其他 shell，例如 `cmd` 或 Git Bash 的 `bash`，可在 **设置 › Shell** 中选择。由于依赖伪控制台，Kero 需要 Windows 10 1809 或更高版本。

### 安装命令行工具

选择 **Kero › 安装命令行工具…**，将 `kero` 加入 `PATH`：在 macOS 上是 `/usr/local/bin` 中的一个链接，在 Linux 上是 `~/.local/bin` 中的链接，在 Windows 上则会把 Kero 的 `bin` 文件夹加入用户 `PATH`，之后新打开的终端即可使用。在任意终端中运行以下命令检查：

```sh
kero help
```

在终端中单独输入 `kero` 会打开应用。

## 打开项目

按 <kbd>⌘</kbd> <kbd>O</kbd> 并选择一个文件夹。Kero 会将其作为项目添加到边栏，并在其中打开一个会话。

你也可以从命令行开始。新会话会归入与其目录匹配的项目：

```sh
cd ~/code/my-app
kero new --focus
```

## 启动智能体

像在任何终端中一样，在会话里运行你的智能体：

```sh
claude
```

或者给它一个单独的会话，并起一个你在边栏中一眼能认出的名字：

```sh
kero new -n fix-login -- claude
```

智能体工作时，会话显示为**工作中**。当它停下来向你提问时，会变为**等待中**，同时 Kero 会通知你。按 <kbd>⌘</kbd> <kbd>J</kbd> 即可跳转过去。

## 退出也不丢失任何内容

按 <kbd>⌘</kbd> <kbd>Q</kbd>。你的会话会继续在 kerod 中运行。再次打开 Kero，它们都还在，回滚缓冲也完好无损。

## 下一步

- [窗格](./panes.md)：拆分会话，在智能体旁边运行开发服务器
- [编程智能体](./agents.md)：运行 `kero skill setup`，让智能体学会使用 Kero
