import { createFileRoute } from '@tanstack/react-router'
import { DocsShell, docsClientLoader } from '@/components/docs-shell'
import { DEFAULT_LANGUAGE } from '@/lib/i18n'
import { loadDocsPage } from '@/lib/docs-loader'

/** English docs. Other languages live under `/$lang/docs` — see `src/lib/i18n.ts`. */
export const Route = createFileRoute('/docs/$')({
  component: Page,
  loader: async ({ params }) => {
    const data = await loadDocsPage({
      data: { slug: params._splat ?? '', lang: DEFAULT_LANGUAGE },
    })
    await docsClientLoader.preload(data.path)
    return data
  },
  head: ({ loaderData }) => ({
    meta: loaderData?.meta ?? [],
  }),
})

function Page() {
  const { _splat } = Route.useParams()
  return (
    <DocsShell lang={DEFAULT_LANGUAGE} slug={_splat ?? ''} data={Route.useLoaderData()} />
  )
}
