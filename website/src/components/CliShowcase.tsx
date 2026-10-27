import { createSignal, For } from 'solid-js';

type Line = { cmd?: string; out?: string; dim?: boolean };

const tabs: { id: string; lines: Line[] }[] = [
  {
    id: 'sessions',
    lines: [
      { cmd: 'kero new -n fix-login -- claude' },
      { out: 'k3f9a2' },
      { cmd: 'kero ls' },
      { out: 'kero' },
      { out: '  k3f9a2  fix-login       working   claude' },
      { out: '  p81c0d  review-pr-42    waiting   codex' },
      { out: '  d07e11  dev server      idle      zsh' },
    ],
  },
  {
    id: 'split',
    lines: [
      { cmd: 'kero split --down -- npm run dev' },
      { out: 'p2c4e8' },
      { cmd: 'kero wait p2c4e8 --for idle --timeout 1m' },
      { out: '  VITE v8.0.0  ready in 212 ms' },
      { out: '  ➜  Local:   http://localhost:5173/' },
    ],
  },
  {
    id: 'prompt',
    lines: [
      { cmd: 'kero prompt review "summarize the diff in two lines"' },
      { out: '● The redirect now keeps its query string after the' },
      { out: '  session expires; loginURL() builds it from the request.' },
      { cmd: 'kero read tests -n 3' },
      { out: 'ok   kero/auth   0.412s' },
    ],
  },
  {
    id: 'remote',
    lines: [
      { cmd: 'kero hosts add devbox me@devbox' },
      { cmd: 'kero -H devbox new -n migrate -- claude' },
      { out: 'm4e7b1' },
      { cmd: 'kero -H devbox ls' },
      { out: 'devbox' },
      { out: '  m4e7b1  migrate         working   claude' },
      { out: '# close your laptop; it keeps running on devbox', dim: true },
    ],
  },
  {
    id: 'report',
    lines: [
      { cmd: 'kero report working "Migrating the database" --progress 40' },
      { cmd: 'kero report blocked "Approve the production deploy?"' },
      { out: '# the session turns to waiting, and Kero notifies you', dim: true },
      { cmd: 'kero report done "Deployed to staging"' },
    ],
  },
];

export default function CliShowcase() {
  const [tab, setTab] = createSignal(tabs[0].id);
  const current = () => tabs.find((t) => t.id === tab())!;
  return (
    <div class="cli-stage">
      <div class="cli-stage__rays" aria-hidden="true" />
      <div class="cli-window">
        {/* Keyed on the tab, so its lines play in again. */}
        <For each={[current()]}>
          {(t) => (
            <pre class="cli-window__body">
              <For each={t.lines}>
                {(line, i) => (
                  <span class="cli-line" style={{ 'animation-delay': `${i() * 90}ms` }}>
                    {line.cmd ? (
                      <>
                        <span class="t-accent">$</span> {line.cmd}
                      </>
                    ) : (
                      <span class={line.dim ? 't-dim' : 't-out'}>{line.out}</span>
                    )}
                    {'\n'}
                  </span>
                )}
              </For>
              <span class="cli-line" style={{ 'animation-delay': `${t.lines.length * 90}ms` }}>
                <span class="t-accent">$</span> <span class="cursor" />
              </span>
            </pre>
          )}
        </For>
        <div class="cli-tabs" role="tablist">
          <For each={tabs}>
            {(t) => (
              <button
                role="tab"
                aria-selected={t.id === tab()}
                classList={{ 'is-active': t.id === tab() }}
                onClick={() => setTab(t.id)}
              >
                {t.id}
              </button>
            )}
          </For>
        </div>
      </div>
    </div>
  );
}
