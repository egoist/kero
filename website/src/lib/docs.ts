import type { Heading } from '../../plugins/markdown';
import sidebarJson from '../../../docs/sidebar.json';
import { localize, locales, t, type Locale } from './i18n';

// The docs live in ../docs, a workspace package of their own, in English,
// with the Japanese in ../docs/ja and the Chinese in ../docs/zh. plugins/markdown compiles each file into
// its HTML, frontmatter and headings.
type DocModule = {
  html: string;
  frontmatter: { title?: string; description?: string };
  headings: Heading[];
};

const modules = import.meta.glob<DocModule>('../../../docs/**/*.md', { eager: true, import: 'default' });

export type Doc = {
  slug: string; // "" for the docs' index
  href: string;
  title: string;
  description: string;
  headings: Heading[];
  html: string;
};

// The docs of each locale by slug. A page not yet translated shows in English.
export const docs: Record<Locale, Map<string, Doc>> = { en: new Map(), ja: new Map(), zh: new Map() };
for (const [file, mod] of Object.entries(modules)) {
  const { locale, name } = docPath(file);
  const slug = name === 'index' ? '' : name.replace(/\/index$/, '');
  docs[locale].set(slug, {
    slug,
    href: localize(slug ? `/docs/${slug}` : '/docs', locale),
    title: mod.frontmatter.title ?? mod.headings.find((h) => h.depth === 1)?.text ?? name,
    description: mod.frontmatter.description ?? '',
    headings: mod.headings,
    html: mod.html,
  });
}
for (const locale of locales.filter((l) => l !== 'en')) {
  for (const [slug, doc] of docs.en) {
    if (!docs[locale].has(slug)) docs[locale].set(slug, { ...doc, href: localize(doc.href, locale) });
  }
}

// A file of ../docs to its locale and its name there: ja/cli.md is cli in ja.
export function docPath(file: string): { locale: Locale; name: string } {
  const path = file.replace(/^.*\/docs\//, '').replace(/\.md$/, '');
  const locale = locales.find((l) => l !== 'en' && path.startsWith(`${l}/`)) ?? 'en';
  return { locale, name: locale === 'en' ? path : path.slice(locale.length + 1) };
}

export type SidebarSection = { title: string; items: Doc[] };

export const sidebar = {} as Record<Locale, SidebarSection[]>;
for (const locale of locales) {
  sidebar[locale] = (sidebarJson as { title: string; items: string[] }[]).map((section) => ({
    title: t(locale).sections[section.title] ?? section.title,
    items: section.items.map((name) => {
      const doc = docs[locale].get(name === 'index' ? '' : name);
      if (!doc) throw new Error(`docs/sidebar.json lists "${name}", but docs/${name}.md is missing`);
      return doc;
    }),
  }));
}

// The docs in sidebar order, for previous and next links.
export const ordered = {} as Record<Locale, Doc[]>;
for (const locale of locales) ordered[locale] = sidebar[locale].flatMap((section) => section.items);
