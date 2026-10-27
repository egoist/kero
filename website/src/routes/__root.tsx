/// <reference types="vite/client" />
import '@fontsource-variable/inter';
import '@fontsource-variable/geist';
import '@fontsource-variable/geist-mono';
import '@fontsource-variable/jetbrains-mono';
import '../styles/markdown.css';
import '../styles/global.css';
import type { JSX } from 'solid-js';
import { HeadContent, Outlet, Scripts, createRootRoute, useLocation } from '@tanstack/solid-router';
import { HydrationScript } from 'solid-js/web';
import SiteHeader from '../components/SiteHeader';
import SiteFooter from '../components/SiteFooter';
import { delocalize, htmlLang, localeOf } from '../lib/i18n';

export const Route = createRootRoute({
  head: () => ({
    meta: [
      { charset: 'utf-8' },
      { name: 'viewport', content: 'width=device-width, initial-scale=1' },
      { name: 'theme-color', content: '#111310' },
      { title: 'Kero' },
    ],
    links: [{ rel: 'icon', type: 'image/png', href: '/favicon.png' }],
    // Umami analytics, only on the built site so dev visits aren't counted.
    scripts: import.meta.env.PROD
      ? [{ defer: true, src: 'https://u.egoist.dev/script.js', 'data-website-id': '03d2a445-d03b-4823-921c-e6285693444e' }]
      : [],
  }),
  shellComponent: RootDocument,
  component: Layout,
});

function RootDocument(props: { children: JSX.Element }) {
  const location = useLocation();
  return (
    <html lang={htmlLang[localeOf(location().pathname)]}>
      <head>
        <HydrationScript />
      </head>
      <body>
        {/* In the body, so it stays in the hydrated tree and follows navigation;
            it portals its tags into <head>. */}
        <HeadContent />
        {props.children}
        <Scripts />
      </body>
    </html>
  );
}

function Layout() {
  const location = useLocation();
  const path = () => location().pathname.replace(/\/$/, '') || '/';
  const locale = () => localeOf(path());
  const page = () => delocalize(path());
  return (
    <div class="site" classList={{ 'site--dark': page() === '/' || page() === '/download' }}>
      <SiteHeader path={path()} locale={locale()} />
      <Outlet />
      <SiteFooter locale={locale()} />
    </div>
  );
}
