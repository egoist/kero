import { createFileRoute } from '@tanstack/solid-router';
import HomePage, { homeHead } from '../components/HomePage';

export const Route = createFileRoute('/')({
  head: () => homeHead('en'),
  component: () => <HomePage locale="en" />,
});
