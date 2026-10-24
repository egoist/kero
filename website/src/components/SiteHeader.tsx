import { createEffect, createSignal, For, on, onCleanup, Show } from 'solid-js';
import { Link } from './Link';
import { GitHubIcon, MenuIcon, XIcon } from './Icons';
import Search from './Search';
import { delocalize, htmlLang, localeName, locales, localize, t, type Locale } from '../lib/i18n';

export const GITHUB_URL = 'https://github.com/egoist/kero';

export default function SiteHeader(props: { path: string; locale: Locale }) {
  const s = () => t(props.locale);
  // The page's own path, without the locale's prefix.
  const page = () => delocalize(props.path);
  const inDocs = () => page().startsWith('/docs');
  const others = () => locales.filter((l) => l !== props.locale);
  const to = (path: string) => localize(path, props.locale);

  // On a phone the links fold into a menu under the header.
  const [open, setOpen] = createSignal(false);
  createEffect(on(() => props.path, () => setOpen(false), { defer: true }));
  let header: HTMLElement | undefined;
  createEffect(() => {
    if (!open()) return;
    const onKeyDown = (e: KeyboardEvent) => e.key === 'Escape' && setOpen(false);
    const onPointerDown = (e: PointerEvent) => !header?.contains(e.target as Node) && setOpen(false);
    document.addEventListener('keydown', onKeyDown);
    document.addEventListener('pointerdown', onPointerDown);
    onCleanup(() => {
      document.removeEventListener('keydown', onKeyDown);
      document.removeEventListener('pointerdown', onPointerDown);
    });
  });

  const links = () => (
    <>
      <Link href={to('/docs')} classList={{ 'is-active': inDocs() && page() !== '/docs/cli' && page() !== '/docs/agents' }}>
        {s().docs}
      </Link>
      <Link href={to('/docs/cli')} classList={{ 'is-active': page() === '/docs/cli' }}>
        {s().cli}
      </Link>
      <Link href={to('/docs/agents')} classList={{ 'is-active': page() === '/docs/agents' }}>
        {s().agents}
      </Link>
      <Link href={to('/download')} classList={{ 'is-active': page() === '/download' }}>
        {s().download}
      </Link>
    </>
  );
  // The same page in each other language.
  const langLinks = (cls?: string) => (
    <For each={others()}>
      {(l) => (
        <Link href={localize(page(), l)} class={cls} hreflang={htmlLang[l]} lang={htmlLang[l]}>
          {localeName[l]}
        </Link>
      )}
    </For>
  );

  return (
    <header class="site-header" ref={header}>
      <div class="wrapper site-header__inner">
        <Link href={to('/')} class="logo" aria-label={s().home}>
          <img src="/icon.png" alt="" width={28} height={28} />
          <span>Kero.</span>
        </Link>
        <nav class="site-nav">{links()}</nav>
        <div class="site-header__end">
          <Search />
          <nav class="lang-links hide-sm" aria-label={s().language}>
            {langLinks('lang-link')}
          </nav>
          <a class="icon-link hide-sm" href={GITHUB_URL} aria-label={s().github}>
            <GitHubIcon size={18} />
          </a>
          <button
            type="button"
            class="icon-link nav-toggle"
            aria-label={open() ? s().closeNav : s().openNav}
            aria-expanded={open()}
            aria-controls="mobile-nav"
            onClick={() => setOpen((o) => !o)}
          >
            {open() ? <XIcon size={20} /> : <MenuIcon size={20} />}
          </button>
        </div>
      </div>
      <Show when={open()}>
        {/* A tap on a link closes it, even one to the page already open. */}
        <nav class="mobile-nav" id="mobile-nav" onClick={(e) => (e.target as Element).closest('a') && setOpen(false)}>
          <div class="mobile-nav__links">{links()}</div>
          <div class="mobile-nav__end">
            {langLinks()}
            <a href={GITHUB_URL} aria-label={s().github}>
              <GitHubIcon size={16} /> GitHub
            </a>
          </div>
        </nav>
      </Show>
    </header>
  );
}
