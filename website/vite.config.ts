import { defineConfig } from 'vite';
import { tanstackStart } from '@tanstack/solid-start/plugin/vite';
import solid from 'vite-plugin-solid';
import { cloudflare } from '@cloudflare/vite-plugin';
import { markdown } from './plugins/markdown';

export default defineConfig({
  plugins: [
    cloudflare({ viteEnvironment: { name: 'ssr' } }),
    // Compiles the Markdown in ../docs, which src/lib/docs.ts imports.
    markdown(),
    tanstackStart({
      // Every page but /download, in each language, is prerendered at
      // build time; that one is rendered by the Worker, so it links to the
      // latest release. A link's #hash or trailing slash isn't another page.
      prerender: {
        enabled: true,
        crawlLinks: true,
        autoSubfolderIndex: false,
        filter: (page) => !/\/download$|#|.\/$/.test(page.path),
      },
    }),
    solid({ ssr: true }),
  ],
});
