import { create, insert, search as zbsearch } from 'zbsearch';
import { docPath, docs, ordered } from './docs';
import type { Locale } from './i18n';

// The search index: one entry per page (its title and intro) and one per
// ## or ### section, for each locale. The search dialog imports this module
// lazily, so the docs' text is fetched the first time someone searches.

export type SearchEntry = {
  href: string; // the page, plus #slug for a section
  page: string;
  heading: string;
  text: string;
  section: boolean;
};

const sources = import.meta.glob<string>('../../../docs/**/*.md', {
  eager: true,
  query: '?raw',
  import: 'default',
});

// Markdown to the words a reader sees: no markers, links, tags or
// container fences. Code is kept, since commands are worth finding.
function plain(md: string) {
  return md
    .replace(/^:::.*$/gm, '')
    .replace(/^```.*$/gm, '')
    .replace(/!\[[^\]]*\]\([^)]*\)/g, '')
    .replace(/\[([^\]]*)\]\([^)]*\)/g, '$1')
    .replace(/<[^>]+>/g, '')
    .replace(/^\s*\|?[\s|:-]*-[\s|:-]*$/gm, '') // a table's rule row
    .replace(/^\s*(?:[-*+]|\d+\.|>)\s+/gm, '')
    .replace(/\|/g, ' ')
    .replace(/[`*]/g, '')
    .replace(/\s+/g, ' ')
    .trim();
}

function entries(locale: Locale): SearchEntry[] {
  const out: SearchEntry[] = [];
  for (const [file, source] of Object.entries(sources)) {
    const { locale: fileLocale, name } = docPath(file);
    if (fileLocale !== locale) continue;
    const doc = docs[locale].get(name === 'index' ? '' : name.replace(/\/index$/, ''));
    if (!doc) continue;

    // The compiled headings carry the slugs the page renders; match them,
    // in order, to the source's ## and ### lines outside code blocks.
    const headings = doc.headings.filter((h) => h.depth === 2 || h.depth === 3);
    const body = source.replace(/^---\n[\s\S]*?\n---\n/, '');
    const parts: { heading?: (typeof headings)[number]; lines: string[] }[] = [{ lines: [] }];
    let fenced = false;
    for (const line of body.split('\n')) {
      if (/^(```|~~~)/.test(line)) fenced = !fenced;
      if (!fenced && /^#{2,3} /.test(line)) {
        parts.push({ heading: headings[parts.length - 1], lines: [] });
        continue;
      }
      if (!fenced && /^# /.test(line)) continue;
      parts.at(-1)!.lines.push(line);
    }

    for (const part of parts) {
      out.push({
        href: part.heading ? `${doc.href}#${part.heading.slug}` : doc.href,
        page: doc.title,
        heading: part.heading?.text ?? doc.title,
        text: plain(part.lines.join('\n')) || (part.heading ? '' : doc.description),
        section: !!part.heading,
      });
    }
  }
  return out;
}

const all = { en: entries('en'), ja: entries('ja'), zh: entries('zh') };
const db = create({ schema: { page: 'string', heading: 'string', text: 'string' } as const });
for (const entry of all.en) insert(db, entry);

// The pages, in sidebar order, for an empty query.
export function pages(locale: Locale) {
  return all[locale]
    .filter((e) => !e.section)
    .sort((a, b) => order(locale, a.href) - order(locale, b.href));
}

function order(locale: Locale, href: string) {
  const i = ordered[locale].findIndex((d) => d.href === href);
  return i < 0 ? Infinity : i;
}

// Entries that match every word of the query, best first: a match in a
// heading counts most, then in the page's title, then in the text.
export async function search(query: string, locale: Locale): Promise<SearchEntry[]> {
  if (locale !== 'en') return searchText(query, all[locale]);
  const results = await zbsearch(db, {
    term: query,
    properties: ['heading', 'page', 'text'],
    boost: { heading: 4, page: 1.5 },
    threshold: 0,
    limit: 40,
  });
  return results.hits.map((hit) => hit.document as unknown as SearchEntry);
}

// Chinese and Japanese have no spaces between words for the index to split
// on, so match each of the query's words as a substring instead, ranked the
// same way.
function searchText(query: string, entries: SearchEntry[]) {
  const terms = query.toLowerCase().split(/\s+/).filter(Boolean);
  const score = (e: SearchEntry) => {
    let total = 0;
    for (const term of terms) {
      const s =
        (e.heading.toLowerCase().includes(term) ? 4 : 0) +
        (e.page.toLowerCase().includes(term) ? 1.5 : 0) +
        (e.text.toLowerCase().includes(term) ? 1 : 0);
      if (!s) return 0;
      total += s;
    }
    return total;
  };
  return entries
    .map((e) => ({ e, s: score(e) }))
    .filter((r) => r.s > 0)
    .sort((a, b) => b.s - a.s)
    .slice(0, 40)
    .map((r) => r.e);
}
