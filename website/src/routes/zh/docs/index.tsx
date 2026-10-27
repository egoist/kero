import { createFileRoute } from '@tanstack/solid-router';
import DocsView, { docHead } from '../../../components/DocsView';

export const Route = createFileRoute('/zh/docs/')({
  head: () => docHead('zh', ''),
  component: () => <DocsView locale="zh" slug="" />,
});
