import { createFileRoute } from '@tanstack/solid-router';
import HomePage, { homeHead } from '../../components/HomePage';

export const Route = createFileRoute('/ja/')({
  head: () => homeHead('ja'),
  component: () => <HomePage locale="ja" />,
});
