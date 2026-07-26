import { DEFAULT_LANGUAGE } from '@/lib/i18n'

export type Row = { name: string; detail: string }

export type HomeCopy = {
  /** Display name of this language, for the footer's switcher. */
  languageName: string
  title: string
  description: string
  /** The tagline is one sentence with a highlighted phrase in the middle. */
  taglineBefore: string
  taglineHighlight: string
  taglineAfter: string
  intro: string
  introFree: string
  download: string
  docs: string
  copy: string
  copied: string
  copyAria: (command: string) => string
  pillNotarized: string
  pillFree: string
  screenshotAlt: string
  screenshotCaption: string
  featuresHeading: string
  shortcutsHeading: string
  faqHeading: string
  features: { group: string; rows: Row[] }[]
  /**
   * Modifiers are spelled out rather than set as ⌘/⇧/⌥/⌃. Geist Mono ships no
   * subset covering U+2318, U+21E7, U+2325, or U+2303, so those glyphs always
   * fall back to another family mid-word — thinner, differently sized, and off
   * the mono grid — and go missing entirely on most non-Apple systems.
   */
  shortcuts: Row[]
  faq: { q: string; a: string }[]
  /** The author's name is a link, so the credit is split around it. */
  footerBuiltBy: { before: string; after: string }
  footerDocs: string
  footerChangelog: string
}

const en: HomeCopy = {
  languageName: 'English',
  title: 'Kero — A native terminal workspace for macOS',
  description:
    'Kero is a fast, keyboard-first terminal workspace for macOS. Projects, sessions, a command palette, and inline git diffs — all in one native window.',
  taglineBefore: 'Your terminal, with the ',
  taglineHighlight: 'whole project',
  taglineAfter: ' around it.',
  intro:
    'A native macOS workspace built around the terminal — projects, persistent sessions, files, and git in one window.',
  introFree: 'Free, no telemetry, no subscription.',
  download: 'Download .dmg',
  docs: 'Docs',
  copy: 'Copy',
  copied: 'Copied',
  copyAria: (command) => `Copy "${command}" to the clipboard`,
  pillNotarized: 'signed & notarized',
  pillFree: 'free & open-source',
  screenshotAlt: "kero showing a project's terminal session with the git panel open",
  screenshotCaption: 'Projects, tabs, the info panel open beside it',
  featuresHeading: 'Features',
  shortcutsHeading: 'Shortcuts',
  faqHeading: 'FAQ',
  features: [
    {
      group: 'projects & sessions',
      rows: [
        {
          name: 'Projects, not windows',
          detail:
            'each repo is a project in the sidebar — Cmd+1–9 switches, Cmd+N adds one',
        },
        {
          name: 'Sessions per project',
          detail:
            'open as many terminal tabs as a project needs with Cmd+T, each with its own directory and scrollback',
        },
        {
          name: 'Split panes',
          detail:
            'Cmd+D splits right, Cmd+Shift+D splits down, Opt+Cmd+arrows moves focus between panes',
        },
        {
          name: 'Restored on relaunch',
          detail:
            'quit and reopen: projects, tabs, and pane layout come back, each shell fresh beneath its previous scrollback',
        },
        {
          name: 'Command palette',
          detail: 'Cmd+P to jump to any project or session, or run any command',
        },
      ],
    },
    {
      group: 'review & ship',
      rows: [
        {
          name: 'Git panel',
          detail:
            'stage, unstage, discard, and commit — amend included — beside the shell that made the changes',
        },
        {
          name: 'Inline diffs',
          detail:
            'click a changed file to read its diff in place, without leaving the window',
        },
        {
          name: 'Branch work',
          detail:
            'switch or create a branch, fetch, fast-forward pull, push, publish a new upstream, or stash',
        },
        {
          name: 'Files panel',
          detail:
            'browse the working tree, open a file, edit it with tree-sitter highlighting, Cmd+S to save',
        },
        {
          name: 'Session info',
          detail:
            'the processes running under a session and the TCP ports they are listening on',
        },
      ],
    },
    {
      group: 'the terminal itself',
      rows: [
        {
          name: 'Your shell, unchanged',
          detail:
            'zsh, fish, or bash exactly as you configured it — prompt, aliases, dotfiles and all',
        },
        {
          name: 'Built on libghostty',
          detail: "Ghostty's terminal core, embedded and hosted natively by kero",
        },
        {
          name: 'Desktop notifications',
          detail:
            'a bell in an unfocused session, or a notification escape from a long-running command, reaches Notification Center',
        },
        {
          name: 'Progress reports',
          detail:
            'OSC 9;4 progress shows as a slim bar above the terminal, error and pause states included',
        },
        {
          name: 'Fonts',
          detail:
            'ships with JetBrains Mono and Nerd Font symbols; swap in any monospace family and size',
        },
        {
          name: 'Quiet updates',
          detail:
            'signed, notarized builds check in with Sparkle and install in the background',
        },
      ],
    },
  ],
  shortcuts: [
    { name: 'Cmd+N', detail: 'new project' },
    { name: 'Cmd+T', detail: 'new session' },
    { name: 'Cmd+W', detail: 'close the focused pane' },
    { name: 'Cmd+1–9', detail: 'switch project' },
    { name: 'Ctrl+Shift+1–9', detail: 'switch tab' },
    { name: 'Ctrl+Tab', detail: 'open the tab switcher' },
    { name: 'Cmd+P', detail: 'command palette' },
    { name: 'Cmd+D / Cmd+Shift+D', detail: 'split right / split down' },
    { name: 'Opt+Cmd+arrows', detail: 'focus the pane in that direction' },
    { name: 'Cmd+[ / Cmd+]', detail: 'cycle pane focus' },
    { name: 'Cmd+Shift+Return', detail: 'zoom the focused pane' },
    { name: 'Ctrl+Cmd+arrows / =', detail: 'resize / equalize panes' },
    { name: 'Cmd+B / Cmd+Shift+B', detail: 'toggle the left / right sidebar' },
    { name: 'Cmd+Shift+G / E / I', detail: 'git / files / info panel' },
    { name: 'Cmd+F / Cmd+G', detail: 'find / find next' },
    { name: 'Cmd+K', detail: 'clear the terminal' },
    { name: 'Cmd+S', detail: 'save the open file' },
  ],
  faq: [
    {
      q: 'Is kero free?',
      a: 'Yes. Free to download, no subscription, no account.',
    },
    {
      q: 'Does it replace my shell?',
      a: 'No. kero hosts the shell you already run and leaves your prompt, aliases, and dotfiles untouched. The terminal underneath is libghostty, the same core as Ghostty.',
    },
    {
      q: 'Does it collect any data?',
      a: 'No telemetry, no analytics. The only network call kero makes is the update check against releases.kero.sh.',
    },
    {
      q: 'What happens to my sessions when I quit?',
      a: 'Projects, tabs, and pane layout come back on relaunch. Each terminal reopens as a fresh shell in its old directory, with the previous scrollback restored above a "Session Contents Restored" divider.',
    },
    {
      q: 'Is this an IDE?',
      a: 'No — the terminal stays the center of gravity. The git and files panels exist so you can review and ship what happens in the terminal without switching to an editor.',
    },
  ],
  footerBuiltBy: { before: 'Built by ', after: '' },
  footerDocs: 'Docs',
  footerChangelog: 'Changelog',
}

const zh: HomeCopy = {
  languageName: '中文',
  title: 'Kero — 原生的 macOS 终端工作区',
  description:
    'Kero 是一个快、以键盘为先的 macOS 终端工作区。项目、会话、命令面板和内联 git diff，都在同一个原生窗口里。',
  taglineBefore: '你的终端，连着',
  taglineHighlight: '整个项目',
  taglineAfter: '。',
  intro:
    '一个围绕终端打造的原生 macOS 工作区——项目、常驻会话、文件与 git，都在同一个窗口里。',
  introFree: '免费，无遥测，无订阅。',
  download: '下载 .dmg',
  docs: '文档',
  copy: '复制',
  copied: '已复制',
  copyAria: (command) => `把“${command}”复制到剪贴板`,
  pillNotarized: '已签名并公证',
  pillFree: '免费开源',
  screenshotAlt: 'kero 中打开了 git 面板的项目终端会话',
  screenshotCaption: '项目、标签页，以及旁边打开的信息面板',
  featuresHeading: '功能',
  shortcutsHeading: '快捷键',
  faqHeading: '常见问题',
  features: [
    {
      group: '项目与会话',
      rows: [
        {
          name: '项目，而不是窗口',
          detail: '每个仓库都是侧边栏里的一个项目——Cmd+1–9 切换，Cmd+N 新建',
        },
        {
          name: '每个项目多个会话',
          detail:
            '用 Cmd+T 按需开任意多个终端标签页，每个都有自己的工作目录和滚动缓冲区',
        },
        {
          name: '分屏窗格',
          detail: 'Cmd+D 向右分屏，Cmd+Shift+D 向下分屏，Opt+Cmd+方向键在窗格之间移动焦点',
        },
        {
          name: '重启后自动恢复',
          detail:
            '退出再打开：项目、标签页和窗格布局都回来，每个 shell 都是新的，跑在它之前的滚动内容下方',
        },
        {
          name: '命令面板',
          detail: 'Cmd+P 跳到任意项目或会话，也可以执行任意命令',
        },
      ],
    },
    {
      group: '审阅与交付',
      rows: [
        {
          name: 'Git 面板',
          detail: '暂存、取消暂存、丢弃、提交——包括 amend——就在产生这些改动的 shell 旁边',
        },
        {
          name: '内联 diff',
          detail: '点一个变更文件，就地读它的 diff，不用离开窗口',
        },
        {
          name: '分支操作',
          detail:
            '切换或新建分支，fetch、fast-forward 拉取、推送、发布新的 upstream，或者 stash',
        },
        {
          name: '文件面板',
          detail: '浏览工作树，打开文件，用 tree-sitter 高亮编辑，Cmd+S 保存',
        },
        {
          name: '会话信息',
          detail: '一个会话底下跑着哪些进程，以及它们监听着哪些 TCP 端口',
        },
      ],
    },
    {
      group: '终端本身',
      rows: [
        {
          name: '你的 shell，原样不动',
          detail: 'zsh、fish 或 bash，你怎么配的就怎么用——提示符、别名、dotfiles 全都在',
        },
        {
          name: '基于 libghostty',
          detail: 'Ghostty 的终端内核，由 kero 内嵌并原生承载',
        },
        {
          name: '桌面通知',
          detail:
            '未聚焦会话里的铃声，或者长时间命令发出的通知转义序列，都会进到「通知中心」',
        },
        {
          name: '进度上报',
          detail: 'OSC 9;4 进度会在终端上方显示为一条细进度条，错误和暂停状态也有',
        },
        {
          name: '字体',
          detail: '内置 JetBrains Mono 和 Nerd Font 符号；也可以换成任意等宽字体和字号',
        },
        {
          name: '安静的更新',
          detail: '签名并公证过的构建通过 Sparkle 检查更新，并在后台安装',
        },
      ],
    },
  ],
  shortcuts: [
    { name: 'Cmd+N', detail: '新建项目' },
    { name: 'Cmd+T', detail: '新建会话' },
    { name: 'Cmd+W', detail: '关闭当前窗格' },
    { name: 'Cmd+1–9', detail: '切换项目' },
    { name: 'Ctrl+Shift+1–9', detail: '切换标签页' },
    { name: 'Ctrl+Tab', detail: '打开标签页切换器' },
    { name: 'Cmd+P', detail: '命令面板' },
    { name: 'Cmd+D / Cmd+Shift+D', detail: '向右分屏 / 向下分屏' },
    { name: 'Opt+Cmd+arrows', detail: '聚焦该方向的窗格' },
    { name: 'Cmd+[ / Cmd+]', detail: '循环切换窗格焦点' },
    { name: 'Cmd+Shift+Return', detail: '放大当前窗格' },
    { name: 'Ctrl+Cmd+arrows / =', detail: '调整窗格大小 / 等分' },
    { name: 'Cmd+B / Cmd+Shift+B', detail: '开合左 / 右侧边栏' },
    { name: 'Cmd+Shift+G / E / I', detail: 'git / 文件 / 信息面板' },
    { name: 'Cmd+F / Cmd+G', detail: '查找 / 查找下一个' },
    { name: 'Cmd+K', detail: '清空终端' },
    { name: 'Cmd+S', detail: '保存当前文件' },
  ],
  faq: [
    {
      q: 'kero 免费吗？',
      a: '免费。下载免费，没有订阅，也不需要账号。',
    },
    {
      q: '它会替换我的 shell 吗？',
      a: '不会。kero 承载的是你已经在用的 shell，不碰你的提示符、别名和 dotfiles。底层终端是 libghostty，和 Ghostty 同一个内核。',
    },
    {
      q: '它会收集数据吗？',
      a: '没有遥测，也没有统计分析。kero 唯一发起的网络请求，是向 releases.kero.sh 检查更新。',
    },
    {
      q: '退出之后我的会话会怎样？',
      a: '项目、标签页和窗格布局会在重启后回来。每个终端都会在原来的目录里以全新的 shell 打开，之前的滚动内容恢复在「Session Contents Restored」分隔线上方。',
    },
    {
      q: '这是一个 IDE 吗？',
      a: '不是——终端始终是重心。git 和文件面板的存在，是为了让你不切到编辑器就能审阅并交付终端里发生的事。',
    },
  ],
  footerBuiltBy: { before: '由 ', after: ' 打造' },
  footerDocs: '文档',
  footerChangelog: '更新日志',
}

const COPY: Record<string, HomeCopy> = { en, zh }

export function homeCopy(lang: string): HomeCopy {
  return COPY[lang] ?? COPY[DEFAULT_LANGUAGE]
}
