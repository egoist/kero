import type { BaseLayoutProps } from 'fumadocs-ui/layouts/shared'

const GITHUB_URL = 'https://github.com/egoist/kero'
const X_URL = 'https://x.com/localhost_4173'

/** The site outside `/docs` is English-only, so these are the only strings to translate. */
const NAV_LABELS = {
  en: { home: 'Home', changelog: 'Changelog', download: 'Download' },
  zh: { home: '首页', changelog: '更新日志', download: '下载' },
} as const

/** Chrome shared by every docs page: the kero wordmark plus links back to the site. */
export function docsLayoutOptions(lang: string): BaseLayoutProps {
  const labels = NAV_LABELS[lang as keyof typeof NAV_LABELS] ?? NAV_LABELS.en

  return {
    githubUrl: GITHUB_URL,
    // The site has no light mode, so a light/dark toggle would be a control
    // that does nothing.
    themeSwitch: { enabled: false },
    nav: {
      url: '/',
      title: (
        <span className="inline-flex items-center gap-2">
          <img
            src="/kero-icon.png"
            alt=""
            width={100}
            height={100}
            className="size-5 rounded-[5px] border border-zinc-600"
          />
          <span className="font-mono font-bold tracking-[0.02em]">kero</span>
        </span>
      ),
    },
    links: [
      { text: labels.home, url: '/', active: 'url' },
      { text: labels.changelog, url: '/changelog', active: 'url' },
      { type: 'button', text: labels.download, url: '/', active: 'none' },
      // Sits beside the GitHub icon `githubUrl` renders.
      {
        type: 'icon',
        label: 'X',
        text: 'X',
        url: X_URL,
        external: true,
        // Explicit size: the icon is a masked span, not the `<svg>` Fumadocs
        // sizes for you, so `size-full` would collapse it to nothing.
        icon: <span className="i-mingcute-social-x-fill size-4" />,
      },
    ],
  }
}
