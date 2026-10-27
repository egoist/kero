import { createEffect, createMemo, createSignal, For, onCleanup, onMount, Show } from 'solid-js';
import { useRouter } from '@tanstack/solid-router';
import { Link } from './Link';
import { docs, ordered, sidebar } from '../lib/docs';
import { pageHead, t, type Locale } from '../lib/i18n';
import { ArrowLeftIcon, ArrowRightIcon, MenuIcon } from './Icons';

// The page's title and description, for a route's head.
export function docHead(locale: Locale, slug: string) {
  const doc = docs[locale].get(slug);
  if (!doc) return {};
  return pageHead(locale, slug ? `/docs/${slug}` : '/docs', `${doc.title} | Kero`, doc.description);
}

export default function DocsView(props: { slug: string; locale: Locale }) {
  const doc = createMemo(() => docs[props.locale].get(props.slug)!);
  const s = () => t(props.locale);
  const index = () => ordered[props.locale].indexOf(doc());
  const prev = () => ordered[props.locale][index() - 1];
  const next = () => ordered[props.locale][index() + 1];
  const section = () => sidebar[props.locale].find((s) => s.items.includes(doc()));
  const toc = () => doc().headings.filter((h) => h.depth === 2 || h.depth === 3);
  const active = useActiveHeading(() => toc().map((h) => h.slug));

  let menu: HTMLDetailsElement | undefined;
  createEffect(() => {
    doc();
    if (menu) menu.open = false; // close the phone menu on navigation
  });

  return (
    <div class="wrapper docs">
      <aside class="docs-sidebar">
        <details class="docs-sidebar__mobile" ref={menu}>
          <summary>
            <MenuIcon size={16} /> {s().menu}
            <span class="muted">/ {doc().title}</span>
          </summary>
          <SidebarNav locale={props.locale} current={doc().href} />
        </details>
        <div class="docs-sidebar__desktop">
          <SidebarNav locale={props.locale} current={doc().href} />
        </div>
      </aside>

      <main class="docs-main">
        <article class="docs-article">
          <Show when={section()}>{(s) => <p class="eyebrow">{s().title}</p>}</Show>
          <div class="markdown" innerHTML={doc().html} {...useContentEvents()} />
        </article>
        <nav class="docs-pager" aria-label={s().pagination}>
          <Show when={prev()} fallback={<span />}>
            {(p) => (
              <Link href={p().href} class="docs-pager__link">
                <span class="docs-pager__label">
                  <ArrowLeftIcon size={14} /> {s().previous}
                </span>
                <span class="docs-pager__title">{p().title}</span>
              </Link>
            )}
          </Show>
          <Show when={next()}>
            {(n) => (
              <Link href={n().href} class="docs-pager__link docs-pager__link--next">
                <span class="docs-pager__label">
                  {s().next} <ArrowRightIcon size={14} />
                </span>
                <span class="docs-pager__title">{n().title}</span>
              </Link>
            )}
          </Show>
        </nav>
      </main>

      <aside class="docs-toc">
        <Show when={toc().length > 0}>
          <p class="docs-toc__title">{s().onThisPage}</p>
          <ul>
            <For each={toc()}>
              {(h) => (
                <li classList={{ 'is-nested': h.depth === 3 }}>
                  <a href={`#${h.slug}`} classList={{ 'is-active': active() === h.slug }}>
                    {h.text}
                  </a>
                </li>
              )}
            </For>
          </ul>
        </Show>
      </aside>
    </div>
  );
}

function SidebarNav(props: { locale: Locale; current: string }) {
  return (
    <nav class="docs-nav">
      <For each={sidebar[props.locale]}>
        {(section) => (
          <div class="docs-nav__section">
            <p class="docs-nav__title">{section.title}</p>
            <ul>
              <For each={section.items}>
                {(item) => (
                  <li>
                    <Link href={item.href} classList={{ 'is-active': item.href === props.current }}>
                      {item.title}
                    </Link>
                  </li>
                )}
              </For>
            </ul>
          </div>
        )}
      </For>
    </nav>
  );
}

// The Markdown renders plain <a> tags, which would reload the whole page.
// Route internal ones through the router like Link does: preload on hover,
// focus or touch, and navigate in place on click. And a code block's copy
// button copies its code.
function useContentEvents() {
  const router = useRouter();
  const internal = (e: Event) => {
    const a = (e.target as Element | null)?.closest?.('a');
    if (!a || a.target || a.hasAttribute('download')) return;
    const url = new URL(a.href, location.href);
    if (url.origin !== location.origin) return;
    // A link to a heading on this page is left to the browser.
    if (url.pathname === location.pathname && url.search === location.search) return;
    return url.pathname + url.search + url.hash;
  };
  const prefetch = (e: Event) => {
    const href = internal(e);
    if (href) void router.preloadRoute({ href } as never).catch(() => {});
  };
  return {
    onMouseOver: prefetch,
    onFocusIn: prefetch,
    onTouchStart: prefetch,
    onClick: (e: MouseEvent) => {
      if (copyCode(e)) return;
      if (e.defaultPrevented || e.button !== 0 || e.metaKey || e.ctrlKey || e.shiftKey || e.altKey) return;
      const href = internal(e);
      if (!href) return;
      e.preventDefault();
      router.history.push(href);
    },
  };
}

// The code beside a clicked copy button, without the empty last line that
// Shiki adds.
function copyCode(e: MouseEvent) {
  const button = (e.target as Element | null)?.closest?.("div[class*='language-'] > button.copy");
  const pre = button?.parentElement?.querySelector('pre');
  if (!button || !pre) return false;
  const lines = Array.from(pre.querySelectorAll('.line'), (l) => l.textContent ?? '');
  if (lines.at(-1) === '') lines.pop();
  navigator.clipboard?.writeText(lines.join('\n')).then(
    () => {
      button.classList.add('copied');
      setTimeout(() => button.classList.remove('copied'), 2000);
    },
    () => {},
  );
  return true;
}

// The heading the reader is at: the last one above the top fifth of the
// viewport.
function useActiveHeading(slugs: () => string[]) {
  const [active, setActive] = createSignal<string | null>(null);
  const update = () => {
    let current: string | null = slugs()[0] ?? null;
    for (const slug of slugs()) {
      const el = document.getElementById(slug);
      if (el && el.getBoundingClientRect().top < window.innerHeight * 0.2) current = slug;
    }
    setActive(current);
  };
  onMount(() => {
    window.addEventListener('scroll', update, { passive: true });
    onCleanup(() => window.removeEventListener('scroll', update));
  });
  createEffect(() => {
    slugs();
    if (typeof window !== 'undefined') queueMicrotask(update);
  });
  return active;
}
