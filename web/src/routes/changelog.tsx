import { createFileRoute } from '@tanstack/react-router'
import changelogSource from '../../../CHANGELOG.md?raw'
import { SiteLayout } from '@/components/site-layout'

const CONTRIBUTORS_URL =
  'https://api.github.com/repos/egoist/kero/contributors?per_page=1&anon=1'
const FALLBACK_CONTRIBUTOR_COUNT = 2

async function getContributorCount() {
  try {
    const response = await fetch(CONTRIBUTORS_URL, {
      headers: {
        Accept: 'application/vnd.github+json',
        'User-Agent': 'kero.sh',
      },
      signal: AbortSignal.timeout(2500),
    })

    if (!response.ok) return FALLBACK_CONTRIBUTOR_COUNT
    if (response.status === 204) return 0

    const lastPage = response.headers
      .get('link')
      ?.match(/[?&]page=(\d+)[^>]*>;\s*rel="last"/)?.[1]
    if (lastPage) return Number(lastPage)

    const contributors: unknown = await response.json()
    return Array.isArray(contributors)
      ? contributors.length
      : FALLBACK_CONTRIBUTOR_COUNT
  } catch {
    return FALLBACK_CONTRIBUTOR_COUNT
  }
}

export const Route = createFileRoute('/changelog')({
  loader: getContributorCount,
  head: () => ({
    meta: [
      { title: 'Changelog — Kero' },
      {
        name: 'description',
        content: 'The latest improvements, fixes, and new features in Kero.',
      },
    ],
  }),
  component: Changelog,
})

type Release = {
  version: string
  notes: string[]
}

const RELEASE_LIMIT = 15

/**
 * CHANGELOG.md also powers Sparkle's in-app release notes. Reading that file at
 * build time keeps the website honest without introducing a second release log.
 */
function parseReleases(markdown: string): Release[] {
  const headings = Array.from(markdown.matchAll(/^## \[([^\]]+)\]\s*$/gm))

  return headings
    .filter((heading) => heading[1] !== 'unrelease')
    .map((heading, index, releasedHeadings) => {
      const bodyStart = (heading.index ?? 0) + heading[0].length
      const bodyEnd = releasedHeadings[index + 1]?.index ?? markdown.length
      const notes: string[] = []

      for (const line of markdown.slice(bodyStart, bodyEnd).split('\n')) {
        if (line.startsWith('- ')) {
          notes.push(line.slice(2).trim())
        } else if (line.trim() && !line.startsWith('#') && notes.length > 0) {
          notes[notes.length - 1] += ` ${line.trim()}`
        }
      }

      return { version: heading[1], notes }
    })
}

const ALL_RELEASES = parseReleases(changelogSource)
const RELEASES = ALL_RELEASES.slice(0, RELEASE_LIMIT)
const HIDDEN_RELEASE_COUNT = ALL_RELEASES.length - RELEASES.length

function Changelog() {
  const latest = RELEASES[0]
  const contributorCount = Route.useLoaderData()

  return (
    <SiteLayout>
      <section className="flex flex-col gap-5">
        <div className="flex items-center gap-3 text-[12px] tracking-[0.08em] text-brand uppercase">
          <span className="size-1.5 rounded-full bg-brand shadow-[0_0_12px_var(--brand)]" />
          Product updates
        </div>
        <div className="flex flex-col gap-3">
          <h2 className="font-sans text-[clamp(2.5rem,8vw,4.5rem)] leading-[0.95] font-semibold tracking-[-0.055em] text-foreground">
            Changelog
          </h2>
          <p className="max-w-[540px] text-muted-foreground">
            What changed in each kero release: new features, improvements, and fixes.
          </p>
        </div>
        <dl className="mt-3 grid grid-cols-3 divide-x divide-border rounded-xl border border-border bg-card/70">
          <Stat
            value={String(ALL_RELEASES.length).padStart(2, '0')}
            label="releases"
          />
          <Stat value={String(contributorCount)} label="contributors" />
          <Stat value={`v${latest?.version ?? '—'}`} label="latest" />
        </dl>
      </section>

      <section
        aria-label={`The last ${RELEASES.length} Kero releases`}
        className="relative ml-2 pl-7 before:absolute before:inset-y-0 before:left-0 before:w-px before:bg-[linear-gradient(to_bottom,var(--border)_0%,var(--border)_92%,transparent_100%)] sm:ml-3 sm:pl-10"
      >
        {RELEASES.map((release, index) => {
          const isLatest = index === 0

          return (
            <article
              id={`v${release.version}`}
              key={release.version}
              className="group relative scroll-mt-8 pb-8 last:pb-0"
            >
              <span
                aria-hidden
                className={`absolute top-[17px] -left-[33px] size-2.5 rounded-full border-2 border-background sm:-left-[45px] ${
                  isLatest ? 'bg-brand shadow-[0_0_14px_var(--brand)]' : 'bg-border'
                }`}
              />
              <div
                className={`rounded-xl border bg-card/60 px-5 py-5 transition-colors sm:px-6 ${
                  isLatest
                    ? 'border-brand/45 bg-brand/[0.045]'
                    : 'border-border hover:border-foreground/20'
                }`}
              >
                <header className="mb-4 flex flex-wrap items-center justify-between gap-3 border-b border-border pb-4">
                  <a
                    href={`#v${release.version}`}
                    className="text-[19px] font-semibold tracking-[-0.02em] text-foreground transition-colors hover:text-brand"
                  >
                    v{release.version}
                  </a>
                  <div className="flex items-center gap-2 text-[11px] tracking-[0.06em] uppercase">
                    {isLatest && (
                      <span className="rounded-full border border-brand/40 bg-brand/10 px-2 py-0.5 text-brand">
                        Latest
                      </span>
                    )}
                    <span className="text-muted-foreground">
                      {String(index + 1).padStart(2, '0')}
                    </span>
                  </div>
                </header>
                <ul className="flex list-none flex-col gap-3 p-0">
                  {release.notes.map((note) => (
                    <li
                      key={note}
                      className="grid grid-cols-[12px_1fr] gap-2.5 text-foreground/90"
                    >
                      <span aria-hidden className="pt-[1px] text-brand">
                        +
                      </span>
                      <span>{note}</span>
                    </li>
                  ))}
                </ul>
              </div>
            </article>
          )
        })}

        {HIDDEN_RELEASE_COUNT > 0 && (
          <div className="pb-5 text-center">
            <p className="text-[12px] text-muted-foreground">
              …plus {HIDDEN_RELEASE_COUNT} earlier{' '}
              {HIDDEN_RELEASE_COUNT === 1 ? 'release' : 'releases'} not shown
              here.
            </p>
          </div>
        )}
      </section>
    </SiteLayout>
  )
}

function Stat({ value, label }: { value: string; label: string }) {
  return (
    <div className="flex min-w-0 flex-col gap-0.5 px-4 py-3.5 sm:px-5">
      <dt className="order-2 truncate text-[10px] tracking-[0.08em] text-muted-foreground uppercase">
        {label}
      </dt>
      <dd className="order-1 truncate text-[15px] text-foreground">{value}</dd>
    </div>
  )
}
