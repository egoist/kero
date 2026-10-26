import { useLocation } from '@tanstack/solid-router';

// The site in English at /, in Japanese under /ja, and in Simplified Chinese
// under /zh.
export type Locale = 'en' | 'ja' | 'zh';
export const locales: Locale[] = ['en', 'ja', 'zh'];

export const htmlLang: Record<Locale, string> = { en: 'en', ja: 'ja', zh: 'zh-CN' };
export const localeName: Record<Locale, string> = { en: 'English', ja: '日本語', zh: '中文' };

export function localeOf(pathname: string): Locale {
  return locales.find((l) => l !== 'en' && new RegExp(`^/${l}(/|$)`).test(pathname)) ?? 'en';
}

// A path of the site, such as /docs/cli, in a locale.
export function localize(path: string, locale: Locale) {
  if (locale === 'en') return path;
  return path === '/' ? `/${locale}` : `/${locale}${path}`;
}

// A path in a locale back to the site's own path.
export function delocalize(pathname: string) {
  return pathname.replace(/^\/(ja|zh)(?=\/|$)/, '') || '/';
}

export function useLocale() {
  const location = useLocation();
  return () => localeOf(location().pathname);
}

// The page's title and description, with links to the page in each locale.
export function pageHead(locale: Locale, path: string, title: string, description: string) {
  return {
    meta: [
      { title },
      { name: 'description', content: description },
      { property: 'og:title', content: title },
      { property: 'og:description', content: description },
    ],
    links: locales.map((l) => ({ rel: 'alternate', hrefLang: htmlLang[l], href: `https://kero.sh${localize(path, l)}` })),
  };
}

// The words of the site's chrome: header, footer, docs and search.
const strings = {
  en: {
    docs: 'Docs',
    cli: 'CLI',
    agents: 'Agents',
    download: 'Download',
    home: 'Kero home',
    github: 'Kero on GitHub',
    tagline: 'a terminal for coding agents',
    configuration: 'Configuration',
    shortcuts: 'Shortcuts',
    menu: 'Menu',
    onThisPage: 'On this page',
    previous: 'Previous',
    next: 'Next',
    pagination: 'Pagination',
    searchDocs: 'Search docs…',
    searchDocsLabel: 'Search docs',
    searchPlaceholder: 'Search the docs…',
    searchDialog: 'Search the docs',
    searchLoading: 'Loading…',
    searchFailed: 'The search index could not be loaded.',
    noResults: (q: string) => `No results for “${q}”`,
    language: 'Language',
    openNav: 'Open menu',
    closeNav: 'Close menu',
    sections: {} as Record<string, string>,
  },
  ja: {
    docs: 'ドキュメント',
    cli: 'CLI',
    agents: 'エージェント',
    download: 'ダウンロード',
    home: 'Kero ホーム',
    github: 'GitHub の Kero',
    tagline: 'コーディングエージェントのためのターミナル',
    configuration: '設定',
    shortcuts: 'ショートカット',
    menu: 'メニュー',
    onThisPage: 'このページの内容',
    previous: '前へ',
    next: '次へ',
    pagination: 'ページ送り',
    searchDocs: 'ドキュメントを検索…',
    searchDocsLabel: 'ドキュメントを検索',
    searchPlaceholder: 'ドキュメントを検索…',
    searchDialog: 'ドキュメントを検索',
    searchLoading: '読み込み中…',
    searchFailed: '検索インデックスを読み込めませんでした。',
    noResults: (q: string) => `“${q}”に一致する結果はありません`,
    language: '言語',
    openNav: 'メニューを開く',
    closeNav: 'メニューを閉じる',
    // docs/sidebar.json's section titles.
    sections: {
      'Getting Started': 'はじめに',
      'Using kero': 'Kero を使う',
      Automation: '自動化',
      Reference: 'リファレンス',
    } as Record<string, string>,
  },
  zh: {
    docs: '文档',
    cli: '命令行',
    agents: '智能体',
    download: '下载',
    home: 'Kero 首页',
    github: 'GitHub 上的 Kero',
    tagline: '为编程智能体打造的终端',
    configuration: '配置',
    shortcuts: '快捷键',
    menu: '目录',
    onThisPage: '本页内容',
    previous: '上一页',
    next: '下一页',
    pagination: '翻页',
    searchDocs: '搜索文档…',
    searchDocsLabel: '搜索文档',
    searchPlaceholder: '搜索文档…',
    searchDialog: '搜索文档',
    searchLoading: '加载中…',
    searchFailed: '无法加载搜索索引。',
    noResults: (q: string) => `没有找到“${q}”的结果`,
    language: '语言',
    openNav: '打开菜单',
    closeNav: '关闭菜单',
    // docs/sidebar.json's section titles.
    sections: {
      'Getting Started': '入门',
      'Using kero': '使用 Kero',
      Automation: '自动化',
      Reference: '参考',
    } as Record<string, string>,
  },
};

export function t(locale: Locale) {
  return strings[locale];
}
