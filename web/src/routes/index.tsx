import { createFileRoute } from '@tanstack/react-router'
import { useEffect, useRef, useState, type ReactNode } from 'react'
import { SiteLayout } from '@/components/site-layout'
import { cn } from '@/lib/utils'

export const Route = createFileRoute('/')({
  component: Home,
  // Fetched per request (SSR) so the page always advertises the newest release.
  loader: () => fetchLatestRelease(),
  staleTime: 5 * 60 * 1000,
})

type Release = { version: string; minSystem: string; dmg: string }

const RELEASES_ORIGIN = 'https://releases.kero.sh'
const APPCAST_URL = `${RELEASES_ORIGIN}/appcast.xml`
const GITHUB_URL = 'https://github.com/egoist/kero'
// Cask lives in egoist/homebrew-tap, so the tap has to be named explicitly.
// `--cask` is optional — brew falls back to casks, and the tap has no `kero` formula.
const BREW_COMMAND = 'brew install egoist/tap/kero'

// Shown only if the appcast can't be reached; kept current so downloads still work.
const FALLBACK: Release = {
  version: '0.1.11',
  minSystem: '15.6',
  dmg: `${RELEASES_ORIGIN}/kero-0.1.11.dmg`,
}

/**
 * Pick the newest release out of the Sparkle appcast — the item with the highest
 * build number (`sparkle:version`). The site links the notarized `.dmg`, which
 * sits beside the `.zip` update enclosure at `kero-<version>.dmg`.
 */
function parseLatestRelease(xml: string): Release | null {
  let best: { build: number; version: string; minSystem: string } | null = null
  for (const [, item] of xml.matchAll(/<item>([\s\S]*?)<\/item>/g)) {
    const version = item
      .match(/<sparkle:shortVersionString>([^<]+)<\/sparkle:shortVersionString>/)?.[1]
      ?.trim()
    if (!version) continue
    const build = Number(
      item.match(/<sparkle:version>([^<]+)<\/sparkle:version>/)?.[1]?.trim() ?? '0',
    )
    const minSystem = item
      .match(/<sparkle:minimumSystemVersion>([^<]+)<\/sparkle:minimumSystemVersion>/)?.[1]
      ?.trim()
    if (!best || build > best.build) {
      best = { build, version, minSystem: minSystem || FALLBACK.minSystem }
    }
  }
  if (!best) return null
  return {
    version: best.version,
    minSystem: best.minSystem,
    dmg: `${RELEASES_ORIGIN}/kero-${best.version}.dmg`,
  }
}

async function fetchLatestRelease(): Promise<Release> {
  try {
    const res = await fetch(APPCAST_URL, {
      signal: AbortSignal.timeout(2500),
      // The site runs as a Cloudflare Worker; cache the appcast at the edge so we
      // don't refetch on every render (matches its own 5-min max-age). `cf` isn't
      // part of the DOM RequestInit type, hence the cast.
      cf: { cacheTtl: 300, cacheEverything: true },
    } as RequestInit & { cf: { cacheTtl: number; cacheEverything: boolean } })
    if (!res.ok) return FALLBACK
    return parseLatestRelease(await res.text()) ?? FALLBACK
  } catch {
    return FALLBACK
  }
}

/* ------------------------------------------------------------------ */

type Row = { name: string; detail: string }

const FEATURES: { group: string; rows: Row[] }[] = [
  {
    group: 'projects & sessions',
    rows: [
      {
        name: 'Projects, not windows',
        detail: 'each repo is a project in the sidebar — Cmd+1–9 switches, Cmd+N adds one',
      },
      {
        name: 'Sessions per project',
        detail:
          'open as many terminal tabs as a project needs with Cmd+T, each with its own directory and scrollback',
      },
      {
        name: 'Split panes',
        detail:
          'Cmd+D splits right, Cmd+Shift+D splits down, Opt+Cmd+arrows moves focus between panes',
      },
      {
        name: 'Restored on relaunch',
        detail:
          'quit and reopen: projects, tabs, and pane layout come back, each shell fresh beneath its previous scrollback',
      },
      {
        name: 'Command palette',
        detail: 'Cmd+P to jump to any project or session, or run any command',
      },
    ],
  },
  {
    group: 'review & ship',
    rows: [
      {
        name: 'Git panel',
        detail:
          'stage, unstage, discard, and commit — amend included — beside the shell that made the changes',
      },
      {
        name: 'Inline diffs',
        detail: 'click a changed file to read its diff in place, without leaving the window',
      },
      {
        name: 'Branch work',
        detail:
          'switch or create a branch, fetch, fast-forward pull, push, publish a new upstream, or stash',
      },
      {
        name: 'Files panel',
        detail:
          'browse the working tree, open a file, edit it with tree-sitter highlighting, Cmd+S to save',
      },
      {
        name: 'Session info',
        detail:
          'the processes running under a session and the TCP ports they are listening on',
      },
    ],
  },
  {
    group: 'the terminal itself',
    rows: [
      {
        name: 'Your shell, unchanged',
        detail: 'zsh, fish, or bash exactly as you configured it — prompt, aliases, dotfiles and all',
      },
      {
        name: 'Built on libghostty',
        detail: "Ghostty's terminal core, embedded and hosted natively by kero",
      },
      {
        name: 'Desktop notifications',
        detail:
          'a bell in an unfocused session, or a notification escape from a long-running command, reaches Notification Center',
      },
      {
        name: 'Progress reports',
        detail: 'OSC 9;4 progress shows as a slim bar above the terminal, error and pause states included',
      },
      {
        name: 'Fonts',
        detail: 'ships with JetBrains Mono and Nerd Font symbols; swap in any monospace family and size',
      },
      {
        name: 'Quiet updates',
        detail: 'signed, notarized builds check in with Sparkle and install in the background',
      },
    ],
  },
]

/**
 * Modifiers are spelled out rather than set as ⌘/⇧/⌥/⌃. Geist Mono ships no
 * subset covering U+2318, U+21E7, U+2325, or U+2303, so those glyphs always
 * fall back to another family mid-word — thinner, differently sized, and off
 * the mono grid — and go missing entirely on most non-Apple systems.
 */
const SHORTCUTS: Row[] = [
  { name: 'Cmd+N', detail: 'new project' },
  { name: 'Cmd+T', detail: 'new session' },
  { name: 'Cmd+W', detail: 'close the focused pane' },
  { name: 'Cmd+1–9', detail: 'switch project' },
  { name: 'Ctrl+Shift+1–9', detail: 'switch tab' },
  { name: 'Ctrl+Tab', detail: 'open the tab switcher' },
  { name: 'Cmd+P', detail: 'command palette' },
  { name: 'Cmd+D / Cmd+Shift+D', detail: 'split right / split down' },
  { name: 'Opt+Cmd+arrows', detail: 'focus the pane in that direction' },
  { name: 'Cmd+[ / Cmd+]', detail: 'cycle pane focus' },
  { name: 'Cmd+Shift+Return', detail: 'zoom the focused pane' },
  { name: 'Ctrl+Cmd+arrows / =', detail: 'resize / equalize panes' },
  { name: 'Cmd+B / Cmd+Shift+B', detail: 'toggle the left / right sidebar' },
  { name: 'Cmd+Shift+G / E / I', detail: 'git / files / info panel' },
  { name: 'Cmd+F / Cmd+G', detail: 'find / find next' },
  { name: 'Cmd+K', detail: 'clear the terminal' },
  { name: 'Cmd+S', detail: 'save the open file' },
]

const FAQ: { q: string; a: ReactNode }[] = [
  {
    q: 'Is kero free?',
    a: 'Yes. Free to download, no subscription, no account.',
  },
  {
    q: 'Does it replace my shell?',
    a: 'No. kero hosts the shell you already run and leaves your prompt, aliases, and dotfiles untouched. The terminal underneath is libghostty, the same core as Ghostty.',
  },
  {
    q: 'Does it collect any data?',
    a: 'No telemetry, no analytics. The only network call kero makes is the update check against releases.kero.sh.',
  },
  {
    q: 'What happens to my sessions when I quit?',
    a: 'Projects, tabs, and pane layout come back on relaunch. Each terminal reopens as a fresh shell in its old directory, with the previous scrollback restored above a "Session Contents Restored" divider.',
  },
  {
    q: 'Is this an IDE?',
    a: 'No — the terminal stays the center of gravity. The git and files panels exist so you can review and ship what happens in the terminal without switching to an editor.',
  },
]

/* ------------------------------------------------------------------ */

function Home() {
  const latest = Route.useLoaderData()
  return (
    <SiteLayout
      headerContent={
        <>
          <p className="text-foreground/70">
            Your terminal, with the{' '}
            <span className="text-brand">whole project</span> around it.
            <span
              aria-hidden
              className="ml-[5px] inline-block h-[1.05em] w-[7px] animate-caret rounded-[1px] bg-brand align-[-0.15em] motion-reduce:animate-none"
            />
          </p>
          <p className="mt-3.5 text-muted-foreground">
            A native macOS workspace built around the terminal — projects, persistent
            sessions, files, and git in one window.
            <br />
            Free, no telemetry, no subscription.
          </p>
        </>
      }
    >
      <section className="flex flex-col gap-3.5">
        <div className="flex flex-wrap items-center gap-2.5">
          <a
            href={latest.dmg}
            download
            className="inline-flex items-center gap-2 rounded-[9px] border border-border bg-card px-4 py-[7px] text-foreground transition-colors hover:border-brand hover:bg-brand/8 hover:text-brand"
          >
            <span className="i-mingcute-apple-fill size-4 shrink-0" />
            Download .dmg
          </a>
          <a
            href={GITHUB_URL}
            target="_blank"
            rel="noreferrer"
            className="inline-flex items-center gap-2 rounded-[9px] border border-border bg-card px-4 py-[7px] text-foreground transition-colors hover:border-brand hover:bg-brand/8 hover:text-brand"
          >
            <span className="i-mingcute-github-fill size-4 shrink-0" />
            GitHub
          </a>
        </div>
        <CopyCommand command={BREW_COMMAND} />
        <div className="flex flex-wrap items-center gap-2 text-[13px] text-muted-foreground">
          <Pill>v{latest.version}</Pill>
          <Pill>macOS {latest.minSystem}+</Pill>
          <Pill>signed &amp; notarized</Pill>
          <Pill>free & open-source</Pill>
        </div>
      </section>

      <figure className="m-0 flex flex-col gap-2">
        <img
          src="/kero-screenshot.png"
          alt="kero showing a project's terminal session with the git panel open"
          width={2286}
          height={1568}
          className="block w-full rounded-lg border border-border bg-card"
        />
        <figcaption className="text-[13px] text-muted-foreground">
          Projects, tabs, the info panel open beside it
        </figcaption>
      </figure>

      <section className="flex flex-col gap-3.5">
        <SectionHeading>Features</SectionHeading>
        <div className="flex flex-col gap-7">
          {FEATURES.map((section) => (
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
        <SectionHeading>Shortcuts</SectionHeading>
        <ul className="grid list-none gap-2 p-0">
          {SHORTCUTS.map((row) => (
            <DefinitionRow key={row.name} {...row} />
          ))}
        </ul>
      </section>

      <section className="flex flex-col gap-3.5">
        <SectionHeading>FAQ</SectionHeading>
        <div className="flex flex-col gap-2">
          {FAQ.map((item) => (
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
function CopyCommand({ command }: { command: string }) {
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
        aria-label={`Copy "${command}" to the clipboard`}
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
          {copied ? 'Copied' : 'Copy'}
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
