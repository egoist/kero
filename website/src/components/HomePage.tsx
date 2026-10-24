import { For } from 'solid-js';
import { Dynamic } from 'solid-js/web';
import { Link } from './Link';
import AppWindow from './AppWindow';
import CliShowcase from './CliShowcase';
import ParticleMorph from './ParticleMorph';
import { ArrowUpRightIcon, BellIcon, BotIcon, LayersIcon, ServerIcon, TerminalIcon } from './Icons';
import { localize, pageHead, type Locale } from '../lib/i18n';

const icons = [LayersIcon, BellIcon, BotIcon, TerminalIcon, ServerIcon];
const featureLinks = ['/docs/sessions', '/docs/status', '/docs/agents', '/docs/configuration', '/docs/remote'];

const copy = {
  en: {
    title: 'A terminal for coding agents | Kero',
    description:
      'Kero is a terminal for coding agents. Sessions keep running when you quit, on your computer or a remote host, and the sidebar shows which ones need you.',
    hero: ['Run your agents.', 'Keep your place.'],
    heroLead:
      'Kero is a terminal for coding agents. Sessions keep running when you quit, and the sidebar shows which ones are working, which need you, and which are done.',
    getStarted: 'Get Started',
    download: 'Download',
    appTitle: 'Every Agent, One Window',
    appLead:
      'An agent reviews your change, lazygit shows the diff, and the program runs beside them. The sidebar tells you which session needs you.',
    cliTitle: 'Drive It From the Shell',
    cliLead:
      "Start sessions, split panes, type into them, wait for them and read their screens, from your shell or your agent's.",
    featuresTitle: 'Built for Many Agents at Once',
    featuresLead:
      'One window for every task in flight, and a clear answer to the only question that matters: who needs you right now?',
    features: [
      {
        title: 'Sessions That Outlive the Window',
        body: 'Sessions run in kerod, a daemon of their own. Quit Kero and they keep going; open it again and everything is where you left it.',
        points: ['Scrollback survives quitting', 'Sessions start again after a reboot', 'Grouped by project in the sidebar'],
        label: 'Sessions & projects',
      },
      {
        title: 'Know Which Ones Need You',
        body: 'Every pane is working, waiting, idle, done or failed. The ones waiting on you stand out, and one shortcut takes you there.',
        points: ['⌘J jumps to the session needing you', 'Notifies you when an agent finishes', 'Dock badge counts who is waiting'],
        label: 'Status & notifications',
      },
      {
        title: 'A CLI Your Agents Can Drive',
        body: 'Agents start dev servers beside themselves, hand work to other agents, wait for tests and report their own progress.',
        points: ['kero split, send, wait and read', 'One command installs the agent skill', 'Works with Claude Code, Codex and more'],
        label: 'Coding agents',
      },
      {
        title: 'Ghostty Under the Hood',
        body: 'Terminals render with libghostty: fast, correct and familiar. Ghostty themes and configuration keys work as you expect.',
        points: ['Every Ghostty theme, light and dark', 'Plain-text config with live reload', 'Rebind any action'],
        label: 'Configuration',
      },
      {
        title: 'Agents on Every Machine',
        body: 'Run sessions on a Linux box, a cloud VM, a Windows PC or the Mac mini under your desk. They join your sidebar, tagged with the host, and keep running when your laptop sleeps.',
        points: [
          'Reach hosts over SSH, Tailscale or WSL',
          'The same statuses, notifications and kero command',
          'One script installs the server build, no root needed',
        ],
        label: 'Remote hosts',
      },
    ],
    ctaTitle: 'Hop In',
    ctaLead: 'Install Kero, teach your agents to use it, and stop losing track of them.',
    ctaComment: '# after installing the command line tool',
    cliReference: 'CLI Reference',
  },
  ja: {
    title: 'コーディングエージェントのためのターミナル | Kero',
    description:
      'Kero はコーディングエージェントのためのターミナルです。終了してもセッションは動き続け、手元のコンピュータでもリモートホストでも、対応が必要なセッションをサイドバーが教えてくれます。',
    hero: ['走らせたまま、', '続きはそのまま。'],
    heroLead:
      'Kero はコーディングエージェントのためのターミナルです。終了してもセッションは動き続け、どれが作業中で、どれが対応待ちで、どれが完了したかをサイドバーが示します。',
    getStarted: 'はじめる',
    download: 'ダウンロード',
    appTitle: 'すべてのエージェントを、ひとつのウインドウに',
    appLead:
      'エージェントが変更をレビューし、lazygit が差分を表示し、その横でプログラムが動く。対応が必要なセッションはサイドバーが教えてくれます。',
    cliTitle: 'シェルから操作する',
    cliLead:
      'あなたのシェルからでもエージェントのシェルからでも、セッションの開始、ペインの分割、入力の送信、完了の待機、画面の読み取りができます。',
    featuresTitle: 'たくさんのエージェントを同時に動かすために',
    featuresLead:
      '進行中のすべてのタスクをひとつのウインドウに。そして、本当に大事な問いにはっきり答えます: 今、誰があなたを必要としているか？',
    features: [
      {
        title: 'ウインドウより長生きするセッション',
        body: 'セッションは専用のデーモン kerod の中で動きます。Kero を終了しても動き続け、再び開けばすべてが元のままです。',
        points: ['終了してもスクロールバックが残る', '再起動後にセッションが再開する', 'サイドバーでプロジェクトごとにまとまる'],
        label: 'セッションとプロジェクト',
      },
      {
        title: '対応が必要なセッションがわかる',
        body: 'すべてのペインは、作業中、待機中、アイドル、完了、失敗のいずれかです。あなたを待っているものは目立ち、ショートカットひとつでそこへ移動できます。',
        points: ['⌘J で対応待ちのセッションへ移動', 'エージェントが完了したら通知', 'Dock のバッジで待機中の数がわかる'],
        label: '状態と通知',
      },
      {
        title: 'エージェントが操作できる CLI',
        body: 'エージェントは自分の横で開発サーバーを起動し、ほかのエージェントに作業を任せ、テストを待ち、自分の進捗を報告できます。',
        points: ['kero split、send、wait、read', 'コマンドひとつでエージェント用スキルをインストール', 'Claude Code や Codex などに対応'],
        label: 'コーディングエージェント',
      },
      {
        title: '中身は Ghostty',
        body: 'ターミナルの描画は libghostty: 速く、正確で、おなじみです。Ghostty のテーマや設定キーが期待どおりに使えます。',
        points: ['Ghostty のすべてのテーマ、ライトもダークも', 'ライブリロード付きのプレーンテキスト設定', 'どのアクションも割り当て直せる'],
        label: '設定',
      },
      {
        title: 'どのマシンでもエージェントを',
        body: 'Linux マシン、クラウドの VM、Windows PC、机の下の Mac mini でセッションを動かせます。ホスト名付きでサイドバーに並び、ノートパソコンがスリープしても動き続けます。',
        points: [
          'SSH、Tailscale、WSL でホストに接続',
          '同じ状態表示、通知、kero コマンド',
          'スクリプトひとつでサーバー版をインストール、root 不要',
        ],
        label: 'リモートホスト',
      },
    ],
    ctaTitle: 'さあ、はじめよう',
    ctaLead: 'Kero をインストールして、エージェントに使い方を教えれば、もう見失うことはありません。',
    ctaComment: '# コマンドラインツールをインストールしたあとで',
    cliReference: 'CLI リファレンス',
  },
  zh: {
    title: '为编程智能体打造的终端 | Kero',
    description:
      'Kero 是为编程智能体打造的终端。退出后会话照常运行，无论在你的电脑上还是远程主机上；边栏告诉你哪些会话需要你。',
    hero: ['智能体一直跑，', '关闭应用也不停。'],
    heroLead: 'Kero 是为编程智能体打造的终端。退出后会话照常运行，边栏告诉你哪些在工作、哪些需要你、哪些已完成。',
    getStarted: '快速上手',
    download: '下载',
    appTitle: '所有智能体，一个窗口',
    appLead: '一个智能体在审查你的改动，lazygit 显示差异，程序在一旁运行。边栏告诉你哪个会话需要你。',
    cliTitle: '在 Shell 里驱动它',
    cliLead: '在你的 Shell 或智能体的 Shell 里新建会话、拆分窗格、向它们输入、等待它们，并读取屏幕内容。',
    featuresTitle: '为同时运行许多智能体而生',
    featuresLead: '一个窗口装下所有进行中的任务，并清楚回答唯一要紧的问题：现在谁需要你？',
    features: [
      {
        title: '会话比窗口活得更久',
        body: '会话运行在独立的守护进程 kerod 中。退出 Kero，它们继续运行；再次打开，一切都还在原处。',
        points: ['退出后回滚缓冲依然保留', '重启电脑后会话自动恢复', '在边栏中按项目分组'],
        label: '会话与项目',
      },
      {
        title: '一眼看出谁需要你',
        body: '每个窗格都处于工作中、等待中、空闲、已完成或失败之一。等待你的会话格外醒目，一个快捷键就能跳过去。',
        points: ['⌘J 跳到需要你的会话', '智能体完成时通知你', '程序坞徽标显示等待中的数量'],
        label: '状态与通知',
      },
      {
        title: '智能体也能驱动的命令行',
        body: '智能体可以在自己旁边启动开发服务器、把工作交给其他智能体、等待测试结果，并报告自己的进度。',
        points: ['kero split、send、wait 和 read', '一条命令安装智能体技能', '支持 Claude Code、Codex 等'],
        label: '编程智能体',
      },
      {
        title: '底层是 Ghostty',
        body: '终端由 libghostty 渲染：快速、准确、熟悉。Ghostty 的主题和配置项都如你所料地生效。',
        points: ['所有 Ghostty 主题，浅色和深色', '纯文本配置，实时重新加载', '任意操作都可以重新绑定'],
        label: '配置',
      },
      {
        title: '每台机器上的智能体',
        body: '在 Linux 服务器、云虚拟机、Windows 电脑或桌下的 Mac mini 上运行会话。它们出现在你的边栏中，标有所在主机，笔记本合上后依然运行。',
        points: ['通过 SSH、Tailscale 或 WSL 连接主机', '同样的状态、通知和 kero 命令', '一个脚本安装服务器版，无需 root'],
        label: '远程主机',
      },
    ],
    ctaTitle: '上车吧',
    ctaLead: '安装 Kero，教会你的智能体使用它，从此不再找不到它们。',
    ctaComment: '# 安装命令行工具之后',
    cliReference: '命令行参考',
  },
};

export function homeHead(locale: Locale) {
  return pageHead(locale, '/', copy[locale].title, copy[locale].description);
}

export default function HomePage(props: { locale: Locale }) {
  const c = () => copy[props.locale];
  const to = (path: string) => localize(path, props.locale);
  return (
    <main class="home">
      {/* Hero */}
      <section class="wrapper hero">
        <div class="hero__copy">
          <h1 class="display">
            <span>{c().hero[0]}</span>
            <br />
            <span>{c().hero[1]}</span>
          </h1>
          <p class="lead">{c().heroLead}</p>
          <div class="actions">
            <Link href={to('/docs/quick-start')} class="button button--primary">
              {c().getStarted}
            </Link>
            <Link href={to('/download')} class="button">
              {c().download}
            </Link>
          </div>
        </div>
        <div class="hero__art">
          <div class="hero__glow" aria-hidden="true" />
          <ParticleMorph />
        </div>
      </section>

      {/* The app */}
      <section class="wrapper section-head">
        <h2 class="title">{c().appTitle}</h2>
        <p class="lead lead--center">{c().appLead}</p>
      </section>
      <section class="wrapper showcase">
        <div class="stage">
          <div class="glass">
            <div class="stage__frame">
              <AppWindow />
            </div>
          </div>
        </div>
      </section>

      <section class="wrapper ticks" aria-hidden="true" />

      {/* CLI */}
      <section class="wrapper section-head">
        <h2 class="title">{c().cliTitle}</h2>
        <p class="lead lead--center">{c().cliLead}</p>
      </section>
      <section class="wrapper wrapper--flush">
        <CliShowcase />
      </section>

      <section class="wrapper ticks" aria-hidden="true" />

      {/* Features, on light */}
      <div class="light">
        <section class="wrapper section-head">
          <h2 class="title">{c().featuresTitle}</h2>
          <p class="lead lead--center">{c().featuresLead}</p>
        </section>
        <section class="wrapper features">
          <For each={c().features}>
            {(f, i) => (
              <article class="feature" classList={{ 'feature--wide': i() === 4 }}>
                <Dynamic component={icons[i()]} size={20} class="feature__icon" />
                <h3>{f.title}</h3>
                <p>{f.body}</p>
                <ul class="checklist">
                  <For each={f.points}>
                    {(p) => (
                      <li>
                        <span class="checklist__mark">[✓]</span>
                        {p}
                      </li>
                    )}
                  </For>
                </ul>
                <Link href={to(featureLinks[i()]!)} class="pill-link">
                  {f.label} <ArrowUpRightIcon size={14} />
                </Link>
              </article>
            )}
          </For>
        </section>
        <section class="wrapper ticks" aria-hidden="true" />
      </div>

      {/* CTA */}
      <section class="wrapper cta">
        <img src="/icon.png" alt="" width={88} height={88} class="cta__icon" />
        <h2 class="title">{c().ctaTitle}</h2>
        <p class="lead lead--center">{c().ctaLead}</p>
        <pre class="cta__code">
          <span class="t-dim">{c().ctaComment}</span>
          {'\n'}
          <span class="t-accent">$</span> kero skill setup{'\n'}
          <span class="t-accent">$</span> kero new -n my-task -- claude
        </pre>
        <div class="actions actions--center">
          <Link href={to('/docs/quick-start')} class="button button--primary">
            {c().getStarted}
          </Link>
          <Link href={to('/docs/cli')} class="button">
            {c().cliReference}
          </Link>
        </div>
      </section>
    </main>
  );
}
