import { fileURLToPath } from 'node:url';
import type { Plugin } from 'vite';
import matter from 'gray-matter';
import MarkdownExit from 'markdown-exit';
import anchor from 'markdown-it-anchor';
import container from 'markdown-it-container';
import { createHighlighter, bundledLanguages, isSpecialLang } from 'shiki';
import { createJavaScriptRegexEngine } from '@shikijs/engine-javascript';

const docsDir = fileURLToPath(new URL('../../docs/', import.meta.url));
const themes = { light: 'github-light', dark: 'github-dark-dimmed' };

export type Heading = { depth: number; slug: string; text: string };

// The language of the page being rendered, for the words the renderer adds:
// the directory of its translation in ../docs, or '' for English.
type Locale = '' | 'ja' | 'zh';
type Env = { locale?: Locale };

const copyCode: Record<Locale, string> = { '': 'Copy Code', ja: 'コードをコピー', zh: '复制代码' };

// Compiles the Markdown in ../docs into modules of { html, frontmatter,
// headings }, which src/lib/docs.ts imports. A ?raw import is left alone.
export function markdown(): Plugin {
  let md: Promise<MarkdownExit> | undefined;
  return {
    name: 'kero-markdown',
    enforce: 'pre',
    async transform(source, id) {
      if (!id.startsWith(docsDir) || !id.endsWith('.md')) return;
      md ??= createCompiler();
      const compiler = await md;
      const locale = (id.slice(docsDir.length).match(/^(ja|zh)\//)?.[1] ?? '') as Locale;
      const { data: frontmatter, content } = matter(docsLinks(source, locale && `/${locale}`));
      const env: Env = { locale };
      const tokens = compiler.parse(content, env);
      const html = await compiler.renderer.renderAsync(tokens, compiler.options, env);
      const out = { html, frontmatter, headings: headings(tokens) };
      return { code: `export default ${JSON.stringify(out)};`, map: null };
    },
  };
}

// The docs link to each other as ./page.md, which reads well on GitHub.
// Served at /docs/page, and /docs for index.md, such links would resolve
// against the wrong directory on /docs, so make them absolute, under /ja and
// /zh for the translations in docs/ja and docs/zh.
function docsLinks(source: string, prefix: string) {
  return source.replace(/\]\(\.\/([\w/-]+)\.md(#[\w-]+)?\)/g, (_, page: string, hash = '') => {
    const path = page === 'index' ? '/docs' : `/docs/${page.replace(/\/index$/, '')}`;
    return `](${prefix}${path}${hash})`;
  });
}

async function createCompiler() {
  const md = new MarkdownExit({ html: true, linkify: true });
  const highlighter = await createHighlighter({
    engine: createJavaScriptRegexEngine(),
    themes: [themes.light, themes.dark],
    langs: [],
  });

  // Highlighted, in a wrapper with the language's name and a copy button,
  // which DocsView wires up.
  md.renderer.rules.fence = async (tokens, idx, _options, env) => {
    const token = tokens[idx]!;
    const label = token.info.trim().split(/\s+/)[0] ?? '';
    let lang = label || 'text';
    if (!isSpecialLang(lang) && !highlighter.getLoadedLanguages().includes(lang)) {
      if (lang in bundledLanguages) await highlighter.loadLanguage(lang as keyof typeof bundledLanguages);
      else lang = 'text';
    }
    const code = highlighter.codeToHtml(token.content, { lang, themes, defaultColor: 'light' });
    return `<div class="language-${label}"><button title="${copyCode[(env as Env).locale ?? '']}" class="copy"></button><span class="lang">${label}</span>${code}</div>`;
  };

  // External links open in a new tab.
  md.renderer.rules.link_open = (tokens, idx, options, _env, self) => {
    const token = tokens[idx]!;
    if (/^[a-z]+:/i.test(token.attrGet('href') ?? '')) {
      token.attrSet('target', '_blank');
      token.attrSet('rel', 'noreferrer');
    }
    return self.renderToken(tokens, idx, options);
  };

  // ::: tip and friends, as VitePress renders them.
  for (const [kind, title, jaTitle, zhTitle] of [
    ['tip', 'TIP', 'ヒント', '提示'],
    ['info', 'INFO', '情報', '信息'],
    ['warning', 'WARNING', '注意', '警告'],
    ['danger', 'DANGER', '危険', '危险'],
  ] as const) {
    md.use(container, kind, {
      render(tokens: { nesting: number; info: string }[], idx: number, _options: unknown, env: Env) {
        const token = tokens[idx]!;
        if (token.nesting !== 1) return '</div>\n';
        const info = token.info.trim().slice(kind.length).trim();
        const cls = 'custom-block-title' + (info ? '' : ' custom-block-title-default');
        return `<div class="${kind} custom-block"><p class="${cls}">${md.renderInline(info || { '': title, ja: jaTitle, zh: zhTitle }[env.locale ?? ''])}</p>\n`;
      },
    });
  }

  md.use(anchor, { permalink: anchor.permalink.ariaHidden({ placement: 'before' }) });
  return md;
}

function headings(tokens: ReturnType<MarkdownExit['parse']>): Heading[] {
  const out: Heading[] = [];
  tokens.forEach((token, i) => {
    if (token.type !== 'heading_open') return;
    const text = (tokens[i + 1]?.children ?? [])
      .filter((child) => child.type === 'text' || child.type === 'code_inline')
      .map((child) => child.content)
      .join('')
      .trim();
    out.push({ depth: Number(token.tag.slice(1)), slug: token.attrGet('id') ?? '', text });
  });
  return out;
}
