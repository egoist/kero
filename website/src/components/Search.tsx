import { createEffect, createMemo, createSignal, For, Index, on, onCleanup, onMount, Show } from 'solid-js';
import { Portal } from 'solid-js/web';
import { useRouter } from '@tanstack/solid-router';
import type { SearchEntry } from '../lib/search';
import { t, useLocale } from '../lib/i18n';
import { FileTextIcon, HashIcon, SearchIcon } from './Icons';

// The index is a chunk of its own, fetched when the search is first opened
// or the pointer rests on its button.
let index: Promise<typeof import('../lib/search')> | undefined;
function loadIndex() {
  index ??= import('../lib/search');
  index.catch(() => (index = undefined));
  return index;
}

export default function Search() {
  const [open, setOpen] = createSignal(false);
  const [mac, setMac] = createSignal(true);
  const locale = useLocale();

  onMount(() => {
    setMac(/Mac|iPhone|iPad/.test(navigator.platform));
    const onKeyDown = (e: KeyboardEvent) => {
      const t = e.target;
      const typing = t instanceof HTMLElement && (t.isContentEditable || /^(INPUT|TEXTAREA|SELECT)$/.test(t.tagName));
      if ((e.key === 'k' && (e.metaKey || e.ctrlKey)) || (e.key === '/' && !typing && !open())) {
        e.preventDefault();
        setOpen((o) => !o);
      }
    };
    document.addEventListener('keydown', onKeyDown);
    onCleanup(() => document.removeEventListener('keydown', onKeyDown));
  });

  const preload = () => void loadIndex().catch(() => {});

  return (
    <>
      <button type="button" class="search-button" onClick={() => setOpen(true)} onPointerEnter={preload}>
        <SearchIcon size={15} />
        {t(locale()).searchDocs}
        <kbd>{mac() ? '⌘K' : 'Ctrl K'}</kbd>
      </button>
      <button
        type="button"
        class="icon-link search-icon-button"
        onClick={() => setOpen(true)}
        onPointerEnter={preload}
        aria-label={t(locale()).searchDocsLabel}
      >
        <SearchIcon size={18} />
      </button>
      <Show when={open()}>
        {/* Inside .site, so the dialog takes the page's light or dark colors. */}
        <Portal mount={document.querySelector('.site') ?? document.body}>
          <SearchDialog onClose={() => setOpen(false)} />
        </Portal>
      </Show>
    </>
  );
}

function SearchDialog(props: { onClose: () => void }) {
  const router = useRouter();
  const locale = useLocale();
  const s = () => t(locale());
  const [query, setQuery] = createSignal('');
  const [search, setSearch] = createSignal<typeof import('../lib/search')>();
  const [failed, setFailed] = createSignal(false);
  const [results, setResults] = createSignal<SearchEntry[]>([]);
  const [selected, setSelected] = createSignal(0);
  let input: HTMLInputElement | undefined;
  let list: HTMLDivElement | undefined;

  loadIndex().then(setSearch, () => setFailed(true));

  onMount(() => {
    input?.focus();
    const html = document.documentElement;
    const overflow = html.style.overflow;
    html.style.overflow = 'hidden';
    onCleanup(() => (html.style.overflow = overflow));
  });

  const terms = createMemo(() => query().toLowerCase().split(/\s+/).filter(Boolean));

  // Results land in order: a slow search for an old query never replaces a
  // newer one's.
  let latest = 0;
  createEffect(
    on([search, query, locale], ([index, q, l]) => {
      if (!index) return;
      const n = ++latest;
      if (!q.trim()) return setResults(index.pages(l));
      void index.search(q, l).then((r) => n === latest && setResults(r));
    }),
  );

  // Grouped by page, in the order each page first ranks.
  const groups = createMemo(() => {
    const byPage = new Map<string, SearchEntry[]>();
    for (const r of results()) byPage.set(r.page, [...(byPage.get(r.page) ?? []), r]);
    return [...byPage.values()];
  });
  const flat = createMemo(() => groups().flat());

  createEffect(
    on(results, () => {
      setSelected(0);
      list?.scrollTo({ top: 0 });
    }),
  );

  createEffect(() => {
    list?.querySelector(`[data-index="${selected()}"]`)?.scrollIntoView({ block: 'nearest' });
  });

  // Fetch the highlighted result's page data ahead of Enter or a click.
  createEffect(() => {
    const entry = flat()[selected()];
    if (entry) void router.preloadRoute({ href: entry.href } as never).catch(() => {});
  });

  function go(entry: SearchEntry | undefined) {
    if (!entry) return;
    props.onClose();
    router.history.push(entry.href);
  }

  function onKeyDown(e: KeyboardEvent) {
    const count = flat().length;
    if (e.key === 'Escape') {
      e.preventDefault();
      props.onClose();
    } else if (e.key === 'ArrowDown' && count) {
      e.preventDefault();
      setSelected((i) => (i + 1) % count);
    } else if (e.key === 'ArrowUp' && count) {
      e.preventDefault();
      setSelected((i) => (i - 1 + count) % count);
    } else if (e.key === 'Enter' && !e.isComposing) {
      e.preventDefault();
      go(flat()[selected()]);
    }
  }

  return (
    <div class="search-dialog" onKeyDown={onKeyDown}>
      <div class="search-dialog__backdrop" onClick={props.onClose} />
      <div class="search-dialog__panel" role="dialog" aria-modal="true" aria-label={s().searchDialog}>
        <div class="search-dialog__field">
          <SearchIcon size={16} />
          <input
            ref={input}
            type="search"
            placeholder={s().searchPlaceholder}
            autocomplete="off"
            spellcheck={false}
            value={query()}
            onInput={(e) => setQuery(e.currentTarget.value)}
            role="combobox"
            aria-expanded="true"
            aria-controls="search-results"
            aria-activedescendant={flat().length ? `search-result-${selected()}` : undefined}
          />
        </div>
        <div class="search-dialog__results" id="search-results" role="listbox" ref={list}>
          <Show
            when={search()}
            fallback={<p class="search-dialog__empty">{failed() ? s().searchFailed : s().searchLoading}</p>}
          >
            <Show when={flat().length} fallback={<p class="search-dialog__empty">{s().noResults(query())}</p>}>
              <For each={groups()}>
                {(group) => (
                  <div class="search-dialog__group" role="group">
                    <Show when={terms().length}>
                      <p class="search-dialog__heading">{group[0]!.page}</p>
                    </Show>
                    <For each={group}>
                      {(entry) => {
                        const i = () => flat().indexOf(entry);
                        return (
                          <a
                            href={entry.href}
                            id={`search-result-${i()}`}
                            data-index={i()}
                            role="option"
                            aria-selected={selected() === i()}
                            class="search-dialog__item"
                            onPointerMove={() => setSelected(i())}
                            onClick={(e) => {
                              if (e.metaKey || e.ctrlKey || e.shiftKey) return;
                              e.preventDefault();
                              go(entry);
                            }}
                          >
                            {entry.section ? <HashIcon size={16} /> : <FileTextIcon size={16} />}
                            <span class="search-dialog__item-body">
                              <span class="search-dialog__item-title">
                                <Highlight text={entry.heading} terms={terms()} />
                              </span>
                              <Show when={terms().length && entry.text}>
                                <span class="search-dialog__item-text">
                                  <Highlight text={snippet(entry.text, terms())} terms={terms()} />
                                </span>
                              </Show>
                            </span>
                          </a>
                        );
                      }}
                    </For>
                  </div>
                )}
              </For>
            </Show>
          </Show>
        </div>
      </div>
    </div>
  );
}

// The text around the first match.
function snippet(text: string, terms: string[]) {
  const lower = text.toLowerCase();
  const at = Math.min(...terms.map((t) => lower.indexOf(t)).filter((i) => i >= 0));
  if (!Number.isFinite(at)) return text.slice(0, 160);
  const start = Math.max(0, lower.lastIndexOf(' ', Math.max(0, at - 40)));
  return (start > 0 ? '…' : '') + text.slice(start, start + 180).trim();
}

function Highlight(props: { text: string; terms: string[] }) {
  const parts = createMemo(() => {
    if (!props.terms.length) return [props.text];
    const escaped = props.terms.map((t) => t.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'));
    return props.text.split(new RegExp(`(${escaped.join('|')})`, 'gi'));
  });
  return <Index each={parts()}>{(part, i) => (i % 2 ? <mark>{part()}</mark> : part())}</Index>;
}
