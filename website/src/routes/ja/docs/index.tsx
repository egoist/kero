import { createFileRoute } from '@tanstack/solid-router';
import DocsView, { docHead } from '../../../components/DocsView';

export const Route = createFileRoute('/ja/docs/')({
  head: () => docHead('ja', ''),
  component: () => <DocsView locale="ja" slug="" />,
});
