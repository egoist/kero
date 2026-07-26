import { createFileRoute, redirect } from '@tanstack/react-router'
import { DocsShell, docsClientLoader } from '@/components/docs-shell'
import { DEFAULT_LANGUAGE } from '@/lib/i18n'
import { loadDocsPage } from '@/lib/docs-loader'

/** Translated docs, e.g. `/zh/docs/git`. English is unprefixed — see `/docs/$`. */
export const Route = createFileRoute('/$lang/docs/$')({
  component: Page,
  beforeLoad: ({ params }) => {
    // English is served without a prefix, so `/en/docs/…` would otherwise be a
    // second URL for a page that already lives at `/docs/…`.
    if (params.lang === DEFAULT_LANGUAGE) {
      throw redirect({
        to: '/docs/$',
        params: { _splat: params._splat ?? '' },
        statusCode: 301,
      })
    }
  },
  loader: async ({ params }) => {
    const data = await loadDocsPage({
      data: { slug: params._splat ?? '', lang: params.lang },
    })
    await docsClientLoader.preload(data.path)
    return data
  },
  head: ({ loaderData }) => ({
    meta: loaderData?.meta ?? [],
  }),
})

function Page() {
  const { lang, _splat } = Route.useParams()
  return <DocsShell lang={lang} slug={_splat ?? ''} data={Route.useLoaderData()} />
}
