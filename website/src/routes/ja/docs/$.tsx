import { createFileRoute, notFound } from '@tanstack/solid-router';
import DocsView, { docHead } from '../../../components/DocsView';
import { docs } from '../../../lib/docs';

export const Route = createFileRoute('/ja/docs/$')({
  loader: ({ params }) => {
    if (!docs.ja.has(params._splat ?? '')) throw notFound();
  },
  head: ({ params }) => docHead('ja', params._splat ?? ''),
  component: DocPage,
});

function DocPage() {
  const params = Route.useParams();
  return <DocsView locale="ja" slug={params()._splat ?? ''} />;
}
