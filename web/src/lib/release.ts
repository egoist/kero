export type Release = { version: string; minSystem: string; dmg: string }

const RELEASES_ORIGIN = 'https://releases.kero.sh'
const APPCAST_URL = `${RELEASES_ORIGIN}/appcast.xml`

export const GITHUB_URL = 'https://github.com/egoist/kero'
export const X_URL = 'https://x.com/localhost_4173'

// Cask lives in egoist/homebrew-tap, so the tap has to be named explicitly.
// `--cask` is optional — brew falls back to casks, and the tap has no `kero` formula.
export const BREW_COMMAND = 'brew install egoist/tap/kero'

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

export async function fetchLatestRelease(): Promise<Release> {
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
