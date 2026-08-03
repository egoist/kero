import { Link } from '@tanstack/react-router'

const X_URL = 'https://x.com/localhost_4173'
const GITHUB_URL = 'https://github.com/egoist/kero'

export function SiteFooter() {
  return (
    <footer className="text-[13px] text-muted-foreground">
      Built by{' '}
      <a
        href={X_URL}
        target="_blank"
        rel="noreferrer"
        className="text-foreground transition-colors hover:text-brand"
      >
        @localhost_4173
      </a>{' '}
      ·{' '}
      <a
        href={GITHUB_URL}
        target="_blank"
        rel="noreferrer"
        className="text-foreground transition-colors hover:text-brand"
      >
        GitHub
      </a>{' '}
      ·{' '}
      <Link
        to="/changelog"
        className="text-foreground transition-colors hover:text-brand"
      >
        Changelog
      </Link>{' '}
      ·{' '}
      <Link
        to="/support"
        className="text-foreground transition-colors hover:text-brand"
      >
        Support
      </Link>{' '}
      ·{' '}
      <Link
        to="/privacy"
        className="text-foreground transition-colors hover:text-brand"
      >
        Privacy
      </Link>{' '}
      · © 2026
    </footer>
  )
}
