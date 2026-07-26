# Kero — website

Landing page and documentation for **Kero**, the native terminal workspace for
macOS.

## Stack

- [TanStack Start](https://tanstack.com/start) (React 19 + Vite 8)
- [Tailwind CSS v4](https://tailwindcss.com)
- [shadcn/ui](https://ui.shadcn.com) with **Base UI** primitives (`@base-ui/react`)
- [Fumadocs](https://fumadocs.dev) for `/docs`
- Deployed to [Cloudflare Workers](https://developers.cloudflare.com/workers/)
  via [`@cloudflare/vite-plugin`](https://developers.cloudflare.com/workers/vite-plugin/)

## Develop

```sh
bun install
bun run dev        # http://localhost:3000 (runs in the Workers runtime)
bun run typecheck  # tsc --noEmit
```

## Deploy (Cloudflare Workers)

```sh
bunx wrangler login   # once, to authenticate
bun run deploy        # vite build → wrangler deploy
```

`bun run build` outputs the Worker + client assets to `dist/`; the
`@cloudflare/vite-plugin` generates the deploy config, so plain `wrangler deploy`
picks it up. `bun run preview` serves the built Worker locally.

Config lives in [`wrangler.jsonc`](wrangler.jsonc) (worker name, compatibility
flags). To serve from `kero.sh`, uncomment the `routes` entry there once the zone
is on Cloudflare. Run `bun run cf-typegen` after adding any bindings.

## Languages

English is the default and stays unprefixed (`/`, `/docs/git`); every other
language sits under its own prefix (`/zh`, `/zh/docs/git`). The supported list
is [`src/lib/i18n.ts`](src/lib/i18n.ts).

**Landing page.** One [`HomePage`](src/components/home-page.tsx) rendered from
per-language strings in [`src/lib/home-copy.ts`](src/lib/home-copy.ts), with a
route per language: [`routes/index.tsx`](src/routes/index.tsx) and
[`routes/zh/index.tsx`](src/routes/zh/index.tsx). Spelling the routes out is
deliberate — a landing page under `/$lang` shares a chunk with `/$lang/docs`,
and once it also shares `HomePage` with `/`, the bundler folds the ~190 kB
Fumadocs bundle into the entry chunk that every page loads. Adding a language
means a route file plus an entry in `home-copy.ts` and in `HOME_ROUTES`
([`src/components/site-links.tsx`](src/components/site-links.tsx)).

**Docs.** MDX under [`content/docs`](content/docs), served by Fumadocs from a
single `/$lang/docs` route. A translation is the same filename with the
language inserted — `git.mdx` → `git.zh.mdx` — and a page with no translation
falls back to English instead of 404ing. Sidebar order and section headings
come from `meta.json` (`meta.zh.json` for the translated labels). A new
language also needs a tokenizer entry in
[`src/routes/api/search.ts`](src/routes/api/search.ts) and a UI language pack in
[`src/components/docs-shell.tsx`](src/components/docs-shell.tsx).

Docs pages are written for people using the app; see
[CONTRIBUTING.md](../CONTRIBUTING.md). Every docs URL is prerendered —
[`vite.config.ts`](vite.config.ts) derives the list from the filenames, so a new
page needs no config change. The landing pages are rendered per request instead,
since they read the current version from the appcast.

## Notes

- The theme lives in [`src/styles/app.css`](src/styles/app.css) — a GitHub-dark
  palette that mirrors the macOS app (`kero/Theme.swift`). Fumadocs reads the
  same variables through `fumadocs-ui/css/shadcn.css`, so the docs inherit it.
- Add more components with `bunx shadcn@latest add <name>` — the project is
  already configured for Base UI (`components.json` → `"style": "base-nova"`).
- The download URL and version live in the `LATEST` constant at the top of
  [`src/routes/index.tsx`](src/routes/index.tsx). Bump it on each release.
- The hero product shot is [`public/kero-screenshot.png`](public/kero-screenshot.png)
  (a real app screenshot with transparent padding + shadow) — swap the file to
  update it.
