import { For, Show, createSignal, onMount } from 'solid-js';
import { Dynamic } from 'solid-js/web';
import { createServerFn } from '@tanstack/solid-start';
import { Link } from './Link';
import { AppleIcon, ArrowUpRightIcon, DownloadIcon, LinuxIcon, WindowsIcon } from './Icons';
import { GITHUB_URL } from './SiteHeader';
import { localize, pageHead, type Locale } from '../lib/i18n';

// The latest published release, whose assets the download links point at:
// mygo.json's version may be a draft still building, or not released at all.
// GitHub redirects releases/latest to its tag, which, unlike the API, has no
// rate limit for the Worker's shared IPs to run into. Cloudflare keeps the
// redirect for a few minutes, as the latest release changes only when one is
// published.
export const latestVersion = createServerFn().handler(async () => {
  const res = await fetch(`${GITHUB_URL}/releases/latest`, {
    redirect: 'manual',
    cf: { cacheTtlByStatus: { '300-399': 300 } },
  } as RequestInit);
  const tag = res.headers.get('location')?.match(/\/releases\/tag\/v([^/?#]+)$/)?.[1];
  if (!tag) throw new Error(`No latest release: ${res.status} ${res.headers.get('location') ?? ''}`);
  return { version: tag };
});

const copy = {
  en: {
    title: 'Download | Kero',
    description: 'Download Kero, a terminal for coding agents, for macOS, Windows and Linux.',
    heading: 'Download Kero',
    lead: 'For macOS, Windows and Linux.',
    notes: (v: string) => `${v} release notes`,
    yours: 'Your system',
    platformNotes: {
      mac: 'Install with Homebrew, or open the disk image and drag Kero into your Applications folder.',
      windows: 'Run the installer, which needs no administrator rights. Kero needs Windows 10 1809 or later.',
      linux: 'Install the package, or run the script to install Kero in ~/.local without root.',
    },
    cliTitle: 'Then, Meet the CLI',
    cli: () => (
      <>
        Choose <strong>Kero › Install Command Line Tool…</strong> to put <code>kero</code> on your PATH, and let your
        agents drive it.
      </>
    ),
    quickStart: 'Quick Start',
    allReleases: 'All Releases',
  },
  ja: {
    title: 'ダウンロード | Kero',
    description: 'コーディングエージェントのためのターミナル Kero を、macOS、Windows、Linux 向けにダウンロード。',
    heading: 'Kero をダウンロード',
    lead: 'macOS、Windows、Linux に対応。',
    notes: (v: string) => `${v} リリースノート`,
    yours: 'お使いのシステム',
    platformNotes: {
      mac: 'Homebrew でインストールするか、ディスクイメージを開いて Kero を“アプリケーション”フォルダにドラッグしてください。',
      windows: 'インストーラを実行してください。管理者権限は不要です。Kero には Windows 10 1809 以降が必要です。',
      linux: 'パッケージをインストールするか、スクリプトを実行して root なしで ~/.local に Kero をインストールしてください。',
    },
    cliTitle: '次は CLI を使ってみよう',
    cli: () => (
      <>
        <strong>Kero › コマンドラインツールをインストール…</strong> を選ぶと <code>kero</code> が PATH
        に追加され、エージェントから操作できるようになります。
      </>
    ),
    quickStart: 'クイックスタート',
    allReleases: 'すべてのリリース',
  },
  zh: {
    title: '下载 | Kero',
    description: '下载 Kero，为编程智能体打造的终端，支持 macOS、Windows 和 Linux。',
    heading: '下载 Kero',
    lead: '支持 macOS、Windows 和 Linux。',
    notes: (v: string) => `${v} 更新说明`,
    yours: '你的系统',
    platformNotes: {
      mac: '用 Homebrew 安装，或打开磁盘映像，把 Kero 拖进“应用程序”文件夹。',
      windows: '运行安装程序，无需管理员权限。Kero 需要 Windows 10 1809 或更高版本。',
      linux: '安装软件包，或运行脚本把 Kero 装到 ~/.local，无需 root。',
    },
    cliTitle: '然后，认识一下命令行',
    cli: () => (
      <>
        选择 <strong>Kero › 安装命令行工具…</strong>，把 <code>kero</code> 加入 PATH，让你的智能体来驱动它。
      </>
    ),
    quickStart: '快速上手',
    allReleases: '所有版本',
  },
};

export function downloadHead(locale: Locale) {
  return pageHead(locale, '/download', copy[locale].title, copy[locale].description);
}

const INSTALL_SCRIPTS: Partial<Record<OS, string>> = {
  mac: 'brew install --cask kero',
  linux: `curl -fsSL ${GITHUB_URL}/releases/latest/download/install.sh | sh`,
};

type OS = 'mac' | 'windows' | 'linux';
type Arch = 'arm' | 'x86';

// The release's assets, named as GitHub names them: the spaces in mygo
// build's names become dots.
const platforms: {
  os: OS;
  name: string;
  icon: typeof AppleIcon;
  files: { label: string; kind: string; arch: Arch; asset: (v: string) => string }[];
}[] = [
  {
    os: 'mac',
    name: 'macOS',
    icon: AppleIcon,
    files: [
      { label: 'Apple Silicon', kind: '.dmg', arch: 'arm', asset: (v) => `Kero.${v}.arm64.dmg` },
      { label: 'Intel', kind: '.dmg', arch: 'x86', asset: (v) => `Kero.${v}.amd64.dmg` },
    ],
  },
  {
    os: 'windows',
    name: 'Windows',
    icon: WindowsIcon,
    files: [
      { label: 'x64', kind: '.exe', arch: 'x86', asset: (v) => `Kero.Setup.${v}.amd64.exe` },
      { label: 'ARM64', kind: '.exe', arch: 'arm', asset: (v) => `Kero.Setup.${v}.arm64.exe` },
    ],
  },
  {
    os: 'linux',
    name: 'Linux',
    icon: LinuxIcon,
    files: [
      { label: 'x64', kind: '.deb', arch: 'x86', asset: (v) => `kero_${v}_amd64.deb` },
      { label: 'ARM64', kind: '.deb', arch: 'arm', asset: (v) => `kero_${v}_arm64.deb` },
    ],
  },
];

type UAData = { platform?: string; getHighEntropyValues?: (hints: string[]) => Promise<{ architecture?: string }> };

function detectOS(): OS | undefined {
  const ua = navigator.userAgent;
  const platform = (navigator as { userAgentData?: UAData }).userAgentData?.platform || navigator.platform || ua;
  if (/mac/i.test(platform)) return 'mac';
  if (/win/i.test(platform)) return 'windows';
  if (/linux|x11/i.test(platform) && !/android/i.test(ua)) return 'linux';
}

// Only Chromium tells the architecture; elsewhere the first file is the pick.
async function detectArch(): Promise<Arch | undefined> {
  const data = (navigator as { userAgentData?: UAData }).userAgentData;
  const arch = await data?.getHighEntropyValues?.(['architecture']).then((v) => v.architecture, () => undefined);
  if (arch === 'arm') return 'arm';
  if (arch === 'x86') return 'x86';
}

export default function DownloadPage(props: { locale: Locale; version: string }) {
  const c = () => copy[props.locale];
  const [os, setOS] = createSignal<OS>();
  const [arch, setArch] = createSignal<Arch>();

  onMount(() => {
    setOS(detectOS());
    detectArch().then(setArch);
  });

  const tag = () => `v${props.version}`;
  const href = (asset: (v: string) => string) =>
    `${GITHUB_URL}/releases/download/${tag()}/${asset(props.version)}`;
  const isPick = (p: (typeof platforms)[number], f: (typeof platforms)[number]['files'][number]) =>
    p.os === os() && (arch() ? f.arch === arch() : f === p.files[0]);

  return (
    <main class="download">
      <section class="wrapper download-head">
        <img src="/icon.png" alt="" width={88} height={88} class="cta__icon" />
        <h1 class="display">{c().heading}</h1>
        <p class="lead lead--center">{c().lead}</p>
        <p class="download-head__version">
          <a href={`${GITHUB_URL}/releases/tag/${tag()}`}>
            {c().notes(tag())} <ArrowUpRightIcon size={13} />
          </a>
        </p>
      </section>

      <section class="wrapper platforms">
        <For each={platforms}>
          {(p) => (
            <article class="platform" classList={{ 'is-yours': p.os === os() }}>
              <div class="platform__head">
                <Dynamic component={p.icon} size={26} class="platform__icon" />
                <h2>{p.name}</h2>
                <Show when={p.os === os()}>
                  <span class="platform__badge">{c().yours}</span>
                </Show>
              </div>
              <p>{c().platformNotes[p.os]}</p>
              <div class="platform__files">
                <For each={p.files}>
                  {(f) => (
                    <a href={href(f.asset)} class="button" classList={{ 'button--primary': isPick(p, f) }}>
                      <DownloadIcon size={16} />
                      {f.label}
                      <span class="platform__kind">{f.kind}</span>
                    </a>
                  )}
                </For>
              </div>
              <Show when={INSTALL_SCRIPTS[p.os]}>
                {(script) => (
                  <pre class="platform__script">
                    <span class="t-accent">$</span> {script()}
                  </pre>
                )}
              </Show>
            </article>
          )}
        </For>
      </section>

      <section class="wrapper cta">
        <h2 class="title">{c().cliTitle}</h2>
        <p class="lead lead--center">{c().cli()}</p>
        <div class="actions actions--center">
          <Link href={localize('/docs/quick-start', props.locale)} class="button button--primary">
            {c().quickStart}
          </Link>
          <a href={`${GITHUB_URL}/releases`} class="button">
            {c().allReleases}
          </a>
        </div>
      </section>
    </main>
  );
}
