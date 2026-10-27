import { createRouter } from '@tanstack/solid-router';
import { routeTree } from './routeTree.gen';

export function getRouter() {
  return createRouter({
    routeTree,
    // Load the destination on hover, focus or touch, which is usually done
    // by the time the click lands.
    defaultPreload: 'intent',
    // Page data is static until the next deploy, so keep it a while.
    defaultPreloadStaleTime: 5 * 60_000,
    scrollRestoration: true,
  });
}

declare module '@tanstack/solid-router' {
  interface Register {
    router: ReturnType<typeof getRouter>;
  }
}
