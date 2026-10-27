import { createFileRoute } from '@tanstack/solid-router';
import DocsView, { docHead } from '../../components/DocsView';

export const Route = createFileRoute('/docs/')({
  head: () => docHead('en', ''),
  component: () => <DocsView locale="en" slug="" />,
});
