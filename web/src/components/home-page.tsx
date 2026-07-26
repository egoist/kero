import { useEffect, useRef, useState, type ReactNode } from 'react'
import { SiteLayout } from '@/components/site-layout'
import { DocsLink } from '@/components/site-links'
import { homeCopy, type Row } from '@/lib/home-copy'
import { BREW_COMMAND, GITHUB_URL, type Release } from '@/lib/release'
import { cn } from '@/lib/utils'

const BUTTON =
  'inline-flex items-center gap-2 rounded-[9px] border border-border bg-card px-4 py-[7px] text-foreground transition-colors hover:border-brand hover:bg-brand/8 hover:text-brand'

/** The landing page, rendered once per language from `homeCopy`. */
export function HomePage({ lang, release }: { lang: string; release: Release }) {
  const copy = homeCopy(lang)

  return (
    <SiteLayout
      lang={lang}
      headerContent={
        <>
          <p className="text-foreground/70">
            {copy.taglineBefore}
            <span className="text-brand">{copy.taglineHighlight}</span>
            {copy.taglineAfter}
            <span
              aria-hidden
              className="ml-[5px] inline-block h-[1.05em] w-[7px] animate-caret rounded-[1px] bg-brand align-[-0.15em] motion-reduce:animate-none"
            />
          </p>
          <p className="mt-3.5 text-muted-foreground">
            {copy.intro}
            <br />
            {copy.introFree}
          </p>
        </>
      }
    >
      <section className="flex flex-col gap-3.5">
        <div className="flex flex-wrap items-center gap-2.5">
          <a href={release.dmg} download className={BUTTON}>
            <span className="i-mingcute-apple-fill size-4 shrink-0" />
            {copy.download}
          </a>
          <DocsLink lang={lang} className={BUTTON}>
            <span className="i-mingcute-book-2-fill size-4 shrink-0" />
            {copy.docs}
          </DocsLink>
          <a href={GITHUB_URL} target="_blank" rel="noreferrer" className={BUTTON}>
            <span className="i-mingcute-github-fill size-4 shrink-0" />
            GitHub
          </a>
        </div>
        <CopyCommand
          command={BREW_COMMAND}
          label={copy.copy}
          copiedLabel={copy.copied}
          aria={copy.copyAria(BREW_COMMAND)}
        />
        <div className="flex flex-wrap items-center gap-2 text-[13px] text-muted-foreground">
          <Pill>v{release.version}</Pill>
          <Pill>macOS {release.minSystem}+</Pill>
          <Pill>{copy.pillFree}</Pill>
        </div>
      </section>

      <figure className="m-0 flex flex-col gap-2">
        <img
          src="/kero-screenshot.png"
          alt={copy.screenshotAlt}
          width={2286}
          height={1568}
          className="block w-full rounded-lg border border-border bg-card"
        />
        <figcaption className="text-[13px] text-muted-foreground">
          {copy.screenshotCaption}
        </figcaption>
      </figure>

      <section className="flex flex-col gap-3.5">
        <SectionHeading>{copy.featuresHeading}</SectionHeading>
        <div className="flex flex-col gap-7">
          {copy.features.map((section) => (
            <div key={section.group} className="flex flex-col gap-3">
              <h3 className="flex items-center gap-3 text-xs font-normal tracking-[0.04em] text-foreground/60 after:h-px after:flex-1 after:bg-border after:content-['']">
                {section.group}
              </h3>
              <ul className="grid list-none gap-2 p-0">
                {section.rows.map((row) => (
                  <DefinitionRow key={row.name} {...row} />
                ))}
              </ul>
            </div>
          ))}
        </div>
      </section>

      <section className="flex flex-col gap-3.5">
        <SectionHeading>{copy.shortcutsHeading}</SectionHeading>
        <ul className="grid list-none gap-2 p-0">
          {copy.shortcuts.map((row) => (
            <DefinitionRow key={row.name} {...row} />
          ))}
        </ul>
      </section>

      <section className="flex flex-col gap-3.5">
        <SectionHeading>{copy.faqHeading}</SectionHeading>
        <div className="flex flex-col gap-2">
          {copy.faq.map((item) => (
            <details key={item.q} className="group border-b border-border">
              <summary className="flex cursor-pointer list-none items-baseline gap-2.5 py-2 text-foreground transition-colors hover:text-brand [&::-webkit-details-marker]:hidden">
                <span
                  aria-hidden
                  className="flex-none text-muted-foreground before:content-['+'] group-open:before:content-['–']"
                />
                {item.q}
              </summary>
              <p className="mb-3 ml-5 text-muted-foreground">{item.a}</p>
            </details>
          ))}
        </div>
      </section>
    </SiteLayout>
  )
}

/* ------------------------------------------------------------------ */

function SectionHeading({ children }: { children: ReactNode }) {
  return (
    <h2 className="text-[13px] font-normal tracking-[0.04em] text-muted-foreground">
      {children}
    </h2>
  )
}

/**
 * The Homebrew one-liner with a copy button, sharing the download button's
 * chrome. The command stays selectable so it's still usable if the Clipboard
 * API isn't available (insecure context, denied permission).
 */
function CopyCommand({
  command,
  label,
  copiedLabel,
  aria,
}: {
  command: string
  label: string
  copiedLabel: string
  aria: string
}) {
  const [copied, setCopied] = useState(false)
  const commandRef = useRef<HTMLSpanElement>(null)

  useEffect(() => {
    if (!copied) return
    const timer = setTimeout(() => setCopied(false), 2000)
    return () => clearTimeout(timer)
  }, [copied])

  const copy = async () => {
    try {
      await navigator.clipboard.writeText(command)
      setCopied(true)
    } catch {
      // Clipboard denied (insecure context, permissions policy). Select the
      // command so ⌘C still works — a button that does nothing reads as broken.
      const node = commandRef.current
      if (!node) return
      const range = document.createRange()
      range.selectNodeContents(node)
      const selection = window.getSelection()
      selection?.removeAllRanges()
      selection?.addRange(range)
    }
  }

  return (
    <div className="flex max-w-full items-stretch self-start overflow-hidden rounded-[9px] border border-border bg-card">
      <code className="flex min-w-0 items-center gap-2 overflow-x-auto px-4 py-[7px] whitespace-pre">
        <span aria-hidden className="shrink-0 text-muted-foreground select-none">
          $
        </span>
        <span ref={commandRef}>{command}</span>
      </code>
      <button
        type="button"
        onClick={copy}
        aria-label={aria}
        className="inline-flex shrink-0 items-center gap-2 border-l border-border px-3.5 text-muted-foreground transition-colors hover:bg-brand/8 hover:text-brand"
      >
        <span
          aria-hidden
          className={cn(
            'size-4 shrink-0',
            copied ? 'i-mingcute-check-line' : 'i-mingcute-copy-2-line',
          )}
        />
        <span aria-live="polite" className="max-[420px]:sr-only">
          {copied ? copiedLabel : label}
        </span>
      </button>
    </div>
  )
}

function Pill({ children }: { children: ReactNode }) {
  return (
    <span className="inline-flex items-center rounded-[6px] border border-border px-2 py-[3px]">
      {children}
    </span>
  )
}

/** A label/description pair — the page's one repeating unit. */
function DefinitionRow({ name, detail }: Row) {
  return (
    <li className="group grid grid-cols-[190px_1fr] items-baseline gap-4 max-[560px]:grid-cols-1 max-[560px]:gap-0.5">
      <span className="text-foreground transition-colors group-hover:text-brand">
        {name}
      </span>
      <span className="text-muted-foreground transition-colors group-hover:text-foreground">
        {detail}
      </span>
    </li>
  )
}
