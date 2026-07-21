import { createFileRoute } from '@tanstack/react-router'
import {
  ArrowDown,
  Command,
  Cpu,
  FolderGit2,
  GitBranch,
  type LucideIcon,
  PanelRight,
  SquareTerminal,
} from 'lucide-react'
import type { ReactNode } from 'react'
import { Button } from '@/components/ui/button'

export const Route = createFileRoute('/')({
  component: Home,
  // Fetched per request (SSR) so the page always advertises the newest release.
  loader: () => fetchLatestRelease(),
  staleTime: 5 * 60 * 1000,
})

type Release = { version: string; minSystem: string; dmg: string }

const RELEASES_ORIGIN = 'https://releases.kero.sh'
const APPCAST_URL = `${RELEASES_ORIGIN}/appcast.xml`

// Shown only if the appcast can't be reached; kept current so downloads still work.
const FALLBACK: Release = {
  version: '0.1.3',
  minSystem: '15.6',
  dmg: `${RELEASES_ORIGIN}/kero-0.1.3.dmg`,
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

const features: { index: string; icon: LucideIcon; title: string; body: string }[] = [
  {
    index: '01',
    icon: FolderGit2,
    title: 'Projects, not windows',
    body: 'Each repo is a project in the sidebar. Switch with ⌘1–9, open a new one with ⌘N. State is remembered.',
  },
  {
    index: '02',
    icon: SquareTerminal,
    title: 'Persistent sessions',
    body: 'Open as many terminal tabs as a project needs. Quit, reopen, and every session is right where you left it.',
  },
  {
    index: '03',
    icon: Command,
    title: 'Command palette',
    body: 'One command palette to jump to any project, session, or file. Keyboard-first, mouse entirely optional.',
  },
  {
    index: '04',
    icon: GitBranch,
    title: 'Git, built in',
    body: 'Stage, commit, and push from a panel beside your shell — with the changed files and diffs right there.',
  },
  {
    index: '05',
    icon: PanelRight,
    title: 'Files & info at hand',
    body: 'Flip the side panel between Git, Files, and Info. Browse the working tree without leaving the window.',
  },
  {
    index: '06',
    icon: Cpu,
    title: 'Native & yours',
    body: 'A real SwiftUI Mac app that runs your shell, your prompt, your dotfiles — and updates itself quietly.',
  },
]

function Home() {
  const latest = Route.useLoaderData()
  return (
    <div className="relative min-h-screen">
      <SiteNav latest={latest} />
      <main>
        <Hero latest={latest} />
        <Features />
        <Details />
        <FinalCta latest={latest} />
      </main>
      <SiteFooter latest={latest} />
    </div>
  )
}

/* ------------------------------------------------------------------ */

function SiteNav({ latest }: { latest: Release }) {
  return (
    <header className="sticky top-0 z-50 border-b border-border/70 bg-background/80 backdrop-blur-md">
      <div className="mx-auto flex h-14 max-w-6xl items-center justify-between px-6">
        <a href="#top" className="flex items-center gap-2.5">
          <img src="/kero-icon.png" alt="Kero" className="size-6 rounded-md" />
          <span className="font-mono text-sm tracking-tight">kero</span>
        </a>
        <nav className="flex items-center gap-1">
          <NavLink href="#features">features</NavLink>
          <NavLink href="#details">how</NavLink>
          <Button
            size="sm"
            className="ml-2 h-8 gap-1.5 rounded-md font-mono text-[13px]"
            render={<a href={latest.dmg} />}
          >
            <span className="i-mingcute-apple-fill size-4" />
            download
          </Button>
        </nav>
      </div>
    </header>
  )
}

function NavLink({ href, children }: { href: string; children: ReactNode }) {
  return (
    <a
      href={href}
      className="hidden rounded-md px-3 py-2 font-mono text-[13px] text-muted-foreground transition-colors hover:text-foreground sm:block"
    >
      {children}
    </a>
  )
}

/* ------------------------------------------------------------------ */

function Hero({ latest }: { latest: Release }) {
  return (
    <section id="top" className="relative overflow-hidden">
      <div aria-hidden className="pointer-events-none absolute inset-0 -z-10">
        <div className="grid-bg absolute inset-x-0 top-0 h-[760px]" />
      </div>

      <div className="mx-auto max-w-6xl px-6 pt-20 sm:pt-28">
        <div className="mx-auto flex max-w-3xl flex-col items-center text-center">
          <div className="inline-flex items-center gap-2 rounded-md border border-border/80 bg-card/60 px-3 py-1 font-mono text-xs text-muted-foreground">
            <span className="text-[#3fb950]">❯</span>
            <span>native terminal workspace · macOS</span>
            <span className="inline-block h-3 w-[7px] animate-caret bg-[#58a6ff]" />
          </div>

          <h1 className="mt-6 text-4xl font-semibold tracking-tight text-balance sm:text-6xl">
            Your terminal, finally organized.
          </h1>

          <p className="mt-5 max-w-xl text-base leading-relaxed text-balance text-muted-foreground sm:text-lg">
            Kero wraps the terminal you already use in projects, persistent
            sessions, a command palette, and built-in git — one fast, native macOS
            window.
          </p>

          <div className="mt-8 flex flex-col items-center gap-3 sm:flex-row">
            <Button
              className="h-11 gap-2 rounded-md px-5 font-mono text-[13px]"
              render={<a href={latest.dmg} />}
            >
              <span className="i-mingcute-apple-fill size-[18px]" />
              Download for macOS
            </Button>
            <Button
              variant="outline"
              className="h-11 gap-1.5 rounded-md px-5 font-mono text-[13px]"
              render={<a href="#features" />}
            >
              See features
              <ArrowDown className="size-4" />
            </Button>
          </div>

          <p className="mt-5 font-mono text-xs text-muted-foreground/70">
            v{latest.version} — macOS {latest.minSystem}+ — free
          </p>
        </div>

        {/* Product shot (transparent padding + shadow baked into the PNG) */}
        <div className="relative mx-auto mt-16 max-w-[1160px] sm:mt-20">
          <div className="aurora pointer-events-none absolute -inset-x-16 -top-28 bottom-0 -z-10 opacity-40 blur-[100px]" />
          <img
            src="/kero-screenshot.png"
            alt="Kero showing a project's terminal session with the git panel open"
            className="relative w-full rounded-4xl select-none"
            draggable={false}
          />
        </div>
      </div>
    </section>
  )
}

/** Four faint HUD corner ticks framing the product shot. */
function Ticks() {
  const base = 'pointer-events-none absolute z-10 font-mono text-sm text-border select-none'
  return (
    <>
      <span className={`${base} top-2 left-2`}>+</span>
      <span className={`${base} top-2 right-2`}>+</span>
      <span className={`${base} bottom-6 left-2`}>+</span>
      <span className={`${base} right-2 bottom-6`}>+</span>
    </>
  )
}

/* ------------------------------------------------------------------ */

function SectionLabel({ children }: { children: ReactNode }) {
  return (
    <div className="flex items-center gap-4">
      <span className="h-px flex-1 bg-border" />
      <span className="font-mono text-xs tracking-[0.25em] text-muted-foreground uppercase">
        {children}
      </span>
      <span className="h-px flex-1 bg-border" />
    </div>
  )
}

function Features() {
  return (
    <section id="features" className="scroll-mt-20">
      <div className="mx-auto max-w-6xl px-6 py-20 sm:py-28">
        <SectionLabel>[ features ]</SectionLabel>

        <div className="mx-auto mt-10 max-w-2xl text-center">
          <h2 className="text-3xl font-semibold tracking-tight text-balance sm:text-4xl">
            A workspace, not just a prompt
          </h2>
          <p className="mt-4 leading-relaxed text-muted-foreground">
            Everything that usually lives in other windows — projects, git,
            files — one keystroke from your shell.
          </p>
        </div>

        <div className="mt-14 grid overflow-hidden rounded-lg border border-border sm:grid-cols-2 lg:grid-cols-3">
          {features.map((f) => (
            <FeatureCell key={f.index} {...f} />
          ))}
        </div>
      </div>
    </section>
  )
}

function FeatureCell({
  index,
  icon: Icon,
  title,
  body,
}: {
  index: string
  icon: LucideIcon
  title: string
  body: string
}) {
  return (
    <div className="group -mt-px -ml-px border-t border-l border-border bg-background p-6 transition-colors hover:bg-card">
      <div className="flex items-center justify-between">
        <span className="font-mono text-xs text-muted-foreground/70 transition-colors group-hover:text-brand">
          {index}
        </span>
        <Icon className="size-[18px] text-muted-foreground/50 transition-colors group-hover:text-foreground" />
      </div>
      <h3 className="mt-5 font-medium">{title}</h3>
      <p className="mt-2 text-sm leading-relaxed text-muted-foreground">{body}</p>
    </div>
  )
}

/* ------------------------------------------------------------------ */

const SHORTCUTS: { keys: string[]; label: string }[] = [
  { keys: ['⌘', '1–9'], label: 'switch project' },
  { keys: ['⌘', 'N'], label: 'new project' },
  { keys: ['⌘', 'K'], label: 'command palette' },
  { keys: ['⌘', ','], label: 'settings' },
]

const SHELLS = ['zsh', 'fish', 'bash', 'starship', 'tmux', 'nvim']

function Details() {
  return (
    <section id="details" className="scroll-mt-20">
      <div className="mx-auto max-w-6xl px-6 py-20 sm:py-28">
        <SectionLabel>[ how it feels ]</SectionLabel>

        <div className="mt-14 grid overflow-hidden rounded-lg border border-border lg:grid-cols-2">
          {/* Keyboard-first */}
          <div className="border-b border-border p-8 lg:border-r lg:border-b-0">
            <div className="font-mono text-xs tracking-[0.2em] text-brand uppercase">
              // keyboard-first
            </div>
            <h3 className="mt-4 text-xl font-semibold tracking-tight">
              Hands stay on the keys
            </h3>
            <p className="mt-2 text-sm leading-relaxed text-muted-foreground">
              Every surface has a shortcut. Move between projects, spawn
              sessions, and summon the palette without reaching for the trackpad.
            </p>
            <div className="mt-6 space-y-2.5">
              {SHORTCUTS.map((s) => (
                <div key={s.label} className="flex items-center gap-3">
                  <div className="flex items-center gap-1">
                    {s.keys.map((k) => (
                      <Kbd key={k}>{k}</Kbd>
                    ))}
                  </div>
                  <span className="font-mono text-[13px] text-muted-foreground">
                    {s.label}
                  </span>
                </div>
              ))}
            </div>
          </div>

          {/* Your shell, unchanged */}
          <div className="p-8">
            <div className="font-mono text-xs tracking-[0.2em] text-brand uppercase">
              // your shell, unchanged
            </div>
            <h3 className="mt-4 text-xl font-semibold tracking-tight">
              It runs your real terminal
            </h3>
            <p className="mt-2 text-sm leading-relaxed text-muted-foreground">
              Kero hosts the shell you already have. Your prompt, aliases, and
              dotfiles come along exactly as they are — nothing to reconfigure.
            </p>
            <div className="mt-6 flex flex-wrap gap-2">
              {SHELLS.map((s) => (
                <span
                  key={s}
                  className="rounded-md border border-border bg-card px-2.5 py-1 font-mono text-[13px] text-muted-foreground"
                >
                  {s}
                </span>
              ))}
            </div>
          </div>
        </div>
      </div>
    </section>
  )
}

function Kbd({ children }: { children: ReactNode }) {
  return (
    <kbd className="inline-flex h-6 min-w-6 items-center justify-center rounded-[5px] border border-border bg-card px-1.5 font-mono text-xs text-foreground">
      {children}
    </kbd>
  )
}

/* ------------------------------------------------------------------ */

function FinalCta({ latest }: { latest: Release }) {
  return (
    <section id="download" className="scroll-mt-20 border-t border-border/70">
      <div className="relative mx-auto max-w-6xl overflow-hidden px-6 py-24 text-center sm:py-32">
        <div className="aurora pointer-events-none absolute inset-x-0 -top-20 -z-10 h-72 opacity-25 blur-[90px]" />
        <img
          src="/kero-icon.png"
          alt=""
          className="mx-auto size-14 rounded-2xl shadow-lg"
        />
        <h2 className="mt-6 text-3xl font-semibold tracking-tight text-balance sm:text-4xl">
          Ready when you are.
        </h2>
        <p className="mx-auto mt-3 max-w-sm text-muted-foreground">
          Download Kero and give every project a home. It's free.
        </p>
        <div className="mt-8 flex justify-center">
          <Button
            className="h-11 gap-2 rounded-md px-6 font-mono text-[13px]"
            render={<a href={latest.dmg} />}
          >
            <span className="i-mingcute-apple-fill size-[18px]" />
            Download for macOS
          </Button>
        </div>
        <p className="mt-5 font-mono text-xs text-muted-foreground/70">
          v{latest.version} — macOS {latest.minSystem}+ — free
        </p>
      </div>
    </section>
  )
}

/* ------------------------------------------------------------------ */

function SiteFooter({ latest }: { latest: Release }) {
  return (
    <footer className="border-t border-border/70">
      <div className="mx-auto flex max-w-6xl flex-col items-center justify-between gap-4 px-6 py-8 font-mono text-[13px] sm:flex-row">
        <div className="flex items-center gap-2.5">
          <img src="/kero-icon.png" alt="" className="size-5 rounded-[5px]" />
          <span>kero</span>
          <span className="text-muted-foreground">
            — native terminal workspace
          </span>
        </div>
        <div className="flex items-center gap-5 text-muted-foreground">
          <a href="#features" className="transition-colors hover:text-foreground">
            features
          </a>
          <a href={latest.dmg} className="transition-colors hover:text-foreground">
            download
          </a>
          <span>© 2026</span>
        </div>
      </div>
    </footer>
  )
}
