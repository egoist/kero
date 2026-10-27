import { createFileRoute, notFound } from '@tanstack/solid-router';
import DocsView, { docHead } from '../../../components/DocsView';
import { docs } from '../../../lib/docs';

export const Route = createFileRoute('/zh/docs/$')({
  loader: ({ params }) => {
    if (!docs.zh.has(params._splat ?? '')) throw notFound();
  },
  head: ({ params }) => docHead('zh', params._splat ?? ''),
  component: DocPage,
});

function DocPage() {
  const params = Route.useParams();
  return <DocsView locale="zh" slug={params()._splat ?? ''} />;
}
