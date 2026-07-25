import type { ReactNode } from "react";
import {
  Outlet,
  createRootRoute,
  HeadContent,
  Scripts,
  useParams,
} from "@tanstack/react-router";
import appCss from "@/styles/app.css?url";
import { DEFAULT_LANGUAGE, isLanguage } from "@/lib/i18n";

export const Route = createRootRoute({
  head: () => ({
    meta: [
      { charSet: "utf-8" },
      { name: "viewport", content: "width=device-width, initial-scale=1" },
      { title: "Kero — A native terminal workspace for macOS" },
      {
        name: "description",
        content:
          "Kero is a fast, keyboard-first terminal workspace for macOS. Projects, sessions, a command palette, and inline git diffs — all in one native window.",
      },
      { name: "theme-color", content: "#0d1117" },
    ],
    links: [
      { rel: "stylesheet", href: appCss },
      { rel: "icon", href: "/favicon.png", type: "image/png" },
      { rel: "apple-touch-icon", href: "/favicon.png" },
    ],
    scripts: [
      import.meta.env.PROD && {
        defer: true,
        src: "https://u.egoist.dev/script.js",
        "data-website-id": "03d2a445-d03b-4823-921c-e6285693444e",
      },
    ].filter((v) => v !== false),
  }),
  component: RootComponent,
});

function RootComponent() {
  return (
    <RootDocument>
      <Outlet />
    </RootDocument>
  );
}

function RootDocument({ children }: Readonly<{ children: ReactNode }>) {
  // Only the translated docs sit under a `/$lang` prefix; everything else is
  // English. `strict: false` so this still works on routes without the param.
  const { lang } = useParams({ strict: false });
  const language = isLanguage(lang) ? lang : DEFAULT_LANGUAGE;

  return (
    <html lang={language} className="dark">
      <head>
        <HeadContent />
      </head>
      <body>
        {children}
        <Scripts />
      </body>
    </html>
  );
}
