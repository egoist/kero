import { Link } from './Link';
import { GITHUB_URL } from './SiteHeader';
import { localize, t, type Locale } from '../lib/i18n';

export default function SiteFooter(props: { locale: Locale }) {
  const s = () => t(props.locale);
  const to = (path: string) => localize(path, props.locale);
  return (
    <footer class="site-footer">
      <div class="wrapper site-footer__inner">
        <div class="site-footer__brand">
          <img src="/icon.png" alt="" width={22} height={22} />
          <span>Kero</span>
          <span class="muted">· {s().tagline}</span>
        </div>
        <nav>
          <Link href={to('/docs')}>{s().docs}</Link>
          <Link href={to('/docs/configuration')}>{s().configuration}</Link>
          <Link href={to('/docs/shortcuts')}>{s().shortcuts}</Link>
          <a href={GITHUB_URL}>GitHub</a>
        </nav>
      </div>
    </footer>
  );
}
