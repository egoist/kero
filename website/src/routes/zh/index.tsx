import { createFileRoute } from '@tanstack/solid-router';
import HomePage, { homeHead } from '../../components/HomePage';

export const Route = createFileRoute('/zh/')({
  head: () => homeHead('zh'),
  component: () => <HomePage locale="zh" />,
});
