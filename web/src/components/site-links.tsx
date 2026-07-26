import { Link } from '@tanstack/react-router'
import type { ReactNode } from 'react'
import { DEFAULT_LANGUAGE } from '@/lib/i18n'

type LinkProps = { lang: string; className?: string; children: ReactNode }

/**
 * Landing pages are spelled-out routes rather than one `/$lang` route — see
 * `routes/zh/index.tsx` for why — so each language maps to its own. Add a
 * language here when you add its route.
 */
const HOME_ROUTES: Record<string, '/' | '/zh'> = { en: '/', zh: '/zh' }

export function HomeLink({ lang, className, children }: LinkProps) {
  return (
    <Link to={HOME_ROUTES[lang] ?? '/'} className={className}>
      {children}
    </Link>
  )
}

/**
 * Docs, in contrast, are one `/$lang/docs` route for every language but the
 * default, which is served unprefixed. TanStack types `to` against the route
 * tree, so both have to be spelled out.
 */
export function DocsLink({ lang, className, children }: LinkProps) {
  return lang === DEFAULT_LANGUAGE ? (
    <Link to="/docs/$" params={{ _splat: '' }} className={className}>
      {children}
    </Link>
  ) : (
    <Link to="/$lang/docs/$" params={{ lang, _splat: '' }} className={className}>
      {children}
    </Link>
  )
}
