import { createFileRoute } from '@tanstack/solid-router';
import DownloadPage, { downloadHead, latestVersion } from '../../components/DownloadPage';

export const Route = createFileRoute('/zh/download')({
  loader: () => latestVersion(),
  staleTime: 5 * 60_000,
  head: () => downloadHead('zh'),
  component: () => <DownloadPage locale="zh" version={Route.useLoaderData()().version} />,
});
