import { splitProps, type JSX } from 'solid-js';
import { Link as RouterLink } from '@tanstack/solid-router';

// A link to a page of the site by its path, which the router preloads on
// hover, focus or touch and opens in place. The router's Link ignores
// classList and marks links active by a looser rule than the site's, so
// classList becomes class and its own active class is left off.
export function Link(props: JSX.AnchorHTMLAttributes<HTMLAnchorElement> & { href: string }) {
  const [own, rest] = splitProps(props, ['href', 'class', 'classList']);
  const cls = () =>
    [
      own.class,
      ...Object.entries(own.classList ?? {})
        .filter(([, on]) => on)
        .map(([name]) => name),
    ]
      .filter(Boolean)
      .join(' ') || undefined;
  return <RouterLink to={own.href} class={cls()} activeProps={{}} {...(rest as object)} />;
}
