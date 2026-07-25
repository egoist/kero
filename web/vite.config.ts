import { readdirSync } from 'node:fs'
import { defineConfig } from 'vite'
import { cloudflare } from '@cloudflare/vite-plugin'
import { tanstackStart } from '@tanstack/react-start/plugin/vite'
import viteReact from '@vitejs/plugin-react'
import tailwindcss from '@tailwindcss/vite'
import mdx from 'fumadocs-mdx/vite'
import { i18n } from './src/lib/i18n'

/**
 * Every docs URL, in every language, so the docs prerender as static pages
 * like the rest of the site. Derived from the filenames: `git.zh.mdx` is the
 * Chinese translation of `git.mdx`, not a page of its own, and a page missing
 * a translation still gets a URL because it falls back to English.
 */
function docsPages() {
  const slugs = readdirSync('content/docs')
    .filter((name) => name.endsWith('.mdx'))
    .map((name) => name.slice(0, -'.mdx'.length))
    .filter((name) => !name.includes('.'))
    .map((name) => (name === 'index' ? '' : `/${name}`))

  return i18n.languages.flatMap((lang) => {
    const prefix = lang === i18n.defaultLanguage ? '' : `/${lang}`
    return slugs.map((slug) => ({ path: `${prefix}/docs${slug}` }))
  })
}

export default defineConfig({
  server: { port: 3000 },
  resolve: { tsconfigPaths: true },
  plugins: [
    cloudflare({ viteEnvironment: { name: 'ssr' } }),
    mdx(),
    tailwindcss(),
    tanstackStart({
      prerender: {
        enabled: true,
        autoStaticPathsDiscovery: false,
        crawlLinks: false,
      },
      pages: [{ path: '/changelog', prerender: { enabled: true } }, ...docsPages()],
      sitemap: { enabled: false },
    }),
    viteReact(),
  ],
})
