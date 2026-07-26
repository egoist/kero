import { notFound } from '@tanstack/react-router'
import { createServerFn } from '@tanstack/react-start'
import { source } from '@/lib/source'

/**
 * Resolves one docs page on the server. Only the page's `path` crosses the
 * wire — the browser fetches the compiled MDX for that path itself, so the
 * payload stays the same size no matter how long the page is.
 */
export const loadDocsPage = createServerFn({ method: 'GET' })
  .validator((params: { slug: string; lang: string }) => params)
  .handler(async ({ data: { slug, lang } }) => {
    const page = source.getPage(slug.split('/').filter(Boolean), lang)
    if (!page) throw notFound()

    return {
      path: page.path,
      pageTree: await source.serializePageTree(source.getPageTree(lang)),
      meta: [
        { title: `${page.data.title} — Kero` },
        ...(page.data.description
          ? [{ name: 'description', content: page.data.description }]
          : []),
      ],
    }
  })
