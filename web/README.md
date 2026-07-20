# Kero — website

Landing page for **Kero**, the native terminal workspace for macOS.

## Stack

- [TanStack Start](https://tanstack.com/start) (React 19 + Vite 8)
- [Tailwind CSS v4](https://tailwindcss.com)
- [shadcn/ui](https://ui.shadcn.com) with **Base UI** primitives (`@base-ui/react`)

## Develop

```sh
bun install
bun run dev        # http://localhost:3000
```

## Build

```sh
bun run build      # client → dist/, server → .output/
bun run start      # serve the production build
bun run typecheck  # tsc --noEmit
```

## Notes

- The theme lives in [`src/styles/app.css`](src/styles/app.css) — a GitHub-dark
  palette that mirrors the macOS app (`kero/Theme.swift`).
- Add more components with `bunx shadcn@latest add <name>` — the project is
  already configured for Base UI (`components.json` → `"style": "base-nova"`).
- The download URL and version live in the `LATEST` constant at the top of
  [`src/routes/index.tsx`](src/routes/index.tsx). Bump it on each release.
- The app-window graphic in the hero is a pure-CSS mock in
  [`src/components/app-window.tsx`](src/components/app-window.tsx).
