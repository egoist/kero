import { createFileRoute } from '@tanstack/react-router'
import { HomePage } from '@/components/home-page'
import { homeCopy } from '@/lib/home-copy'
import { fetchLatestRelease } from '@/lib/release'

const LANG = 'zh'

/**
 * The Chinese landing page. Spelled out rather than served from `/$lang`,
 * because a route there shares a chunk with `/$lang/docs` — and once it also
 * shares `HomePage` with `/`, the bundler folds the ~190 kB Fumadocs bundle
 * into the entry chunk that every page loads.
 */
export const Route = createFileRoute('/zh/')({
  component: Home,
  // Fetched per request (SSR) so the page always advertises the newest release.
  loader: () => fetchLatestRelease(),
  staleTime: 5 * 60 * 1000,
  head: () => {
    const copy = homeCopy(LANG)
    return {
      meta: [
        { title: copy.title },
        { name: 'description', content: copy.description },
      ],
    }
  },
})

function Home() {
  return <HomePage lang={LANG} release={Route.useLoaderData()} />
}
