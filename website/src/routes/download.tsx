import { createFileRoute } from '@tanstack/solid-router';
import DownloadPage, { downloadHead, latestVersion } from '../components/DownloadPage';

export const Route = createFileRoute('/download')({
  loader: () => latestVersion(),
  staleTime: 5 * 60_000,
  head: () => downloadHead('en'),
  component: () => <DownloadPage locale="en" version={Route.useLoaderData()().version} />,
});
