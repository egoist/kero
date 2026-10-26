import { createFileRoute } from '@tanstack/solid-router';
import DownloadPage, { downloadHead, latestVersion } from '../../components/DownloadPage';

export const Route = createFileRoute('/ja/download')({
  loader: () => latestVersion(),
  staleTime: 5 * 60_000,
  head: () => downloadHead('ja'),
  component: () => <DownloadPage locale="ja" version={Route.useLoaderData()().version} />,
});
