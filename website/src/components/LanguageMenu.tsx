import { createEffect, createSignal, For, on, onCleanup, Show } from 'solid-js';
import { Link } from './Link';
import { CheckIcon, ChevronDownIcon, GlobeIcon } from './Icons';
import { htmlLang, localeName, locales, localize, t, type Locale } from '../lib/i18n';

// A button naming the page's language, which opens a menu of the same page
// in each language. In the phone's menu (inline) the list opens in place,
// under the button, instead of floating over the page.
export default function LanguageMenu(props: { locale: Locale; page: string; path: string; inline?: boolean; class?: string }) {
  const [open, setOpen] = createSignal(false);
  createEffect(on(() => props.path, () => setOpen(false), { defer: true }));
  let root: HTMLDivElement | undefined;
  let button: HTMLButtonElement | undefined;
  createEffect(() => {
    if (!open()) return;
    const onKeyDown = (e: KeyboardEvent) => {
      if (e.key !== 'Escape') return;
      // Closes this menu, not the phone's menu around it.
      e.stopPropagation();
      setOpen(false);
      button?.focus();
    };
    const onPointerDown = (e: PointerEvent) => !root?.contains(e.target as Node) && setOpen(false);
    document.addEventListener('keydown', onKeyDown, true);
    document.addEventListener('pointerdown', onPointerDown);
    onCleanup(() => {
      document.removeEventListener('keydown', onKeyDown, true);
      document.removeEventListener('pointerdown', onPointerDown);
    });
  });

  return (
    <div class={['lang-menu', props.inline && 'lang-menu--inline', props.class].filter(Boolean).join(' ')} ref={root}>
      <button
        type="button"
        class="lang-menu__button"
        ref={button}
        aria-label={t(props.locale).language}
        aria-haspopup="true"
        aria-expanded={open()}
        aria-controls={props.inline ? 'lang-menu-inline' : 'lang-menu'}
        onClick={() => setOpen((o) => !o)}
      >
        <GlobeIcon size={16} />
        <span>{localeName[props.locale]}</span>
        <ChevronDownIcon size={14} class="lang-menu__chevron" />
      </button>
      <Show when={open()}>
        <ul class="lang-menu__list" id={props.inline ? 'lang-menu-inline' : 'lang-menu'}>
          <For each={locales}>
            {(l) => (
              <li>
                <Link
                  href={localize(props.page, l)}
                  hreflang={htmlLang[l]}
                  lang={htmlLang[l]}
                  aria-current={l === props.locale ? 'page' : undefined}
                  onClick={() => setOpen(false)}
                >
                  <span>{localeName[l]}</span>
                  <Show when={l === props.locale}>
                    <CheckIcon size={14} />
                  </Show>
                </Link>
              </li>
            )}
          </For>
        </ul>
      </Show>
    </div>
  );
}
