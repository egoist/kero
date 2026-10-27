import { createSignal, For, onCleanup, onMount, Show, type JSX } from 'solid-js';
import sidebarSvg from '../../../icons/f7-sidebar-left.svg?raw';
import plusSvg from '../../../icons/f7-plus.svg?raw';
import folderSvg from '../../../icons/f7-folder.svg?raw';
import searchSvg from '../../../icons/f7-search.svg?raw';
import gearSvg from '../../../icons/f7-gear-alt.svg?raw';
import terminalSvg from '../../../icons/meteor-terminal.svg?raw';
import splitRightSvg from '../../../icons/f7-square-split-2x1.svg?raw';
import splitDownSvg from '../../../icons/f7-square-split-1x2.svg?raw';
import zoomSvg from '../../../icons/f7-arrow-up-left-arrow-down-right.svg?raw';
import closeSvg from '../../../icons/f7-xmark.svg?raw';

// Kero's window, drawn in HTML so it stays sharp at any size: a project's
// sessions in the sidebar, and a session split into Claude Code reviewing
// a change, lazygit showing it, and the program running, with a project
// whose sessions run on a remote host. The snake plays
// itself while the window shows.

type Status = 'idle' | 'waiting' | 'working' | 'done';

const projects: { name: string; host?: string; note?: string; sessions: { name: string; status: Status; selected?: boolean; bold?: boolean }[] }[] = [
  {
    name: 'snake',
    note: '1 needs you',
    sessions: [
      { name: 'Review --size flag', status: 'idle', selected: true },
      { name: 'Add high scores', status: 'waiting', bold: true },
    ],
  },
  {
    name: 'website',
    sessions: [
      { name: 'Fix flaky e2e test', status: 'working' },
      { name: 'Docs dev server', status: 'idle' },
      { name: 'Write CLI docs', status: 'done', bold: true },
    ],
  },
  {
    name: 'api',
    host: 'devbox',
    sessions: [{ name: 'Migrate the database', status: 'working' }],
  },
];

export default function AppWindow() {
  return (
    <div class="kw" role="img" aria-label="Kero's window: Claude Code reviewing a change, lazygit showing its diff and a snake game running in split panes, beside a sidebar of sessions grouped by project, one of them on a remote host">
      <aside class="kw-side">
        <div class="kw-side__top">
          <span class="kw-lights">
            <i />
            <i />
            <i />
          </span>
          <span class="kw-side__tools">
            <SidebarIcon />
            <PlusIcon />
          </span>
        </div>
        <For each={projects}>
          {(p) => (
            <div class="kw-project">
              <p class="kw-project__head">
                <span>
                  {p.name}
                  <Show when={p.host}>
                    {' '}
                    <span class="kw-host">{p.host}</span>
                  </Show>{' '}
                  <span class="kw-count">{p.sessions.length}</span>
                </span>
                <Show when={p.note}>
                  <span class="kw-attention">{p.note}</span>
                </Show>
              </p>
              <For each={p.sessions}>
                {(s) => (
                  <div class="kw-session" classList={{ 'is-selected': !!s.selected, 'is-bold': !!s.bold }}>
                    <span class="kw-session__name">{s.name}</span>
                    <span class="kw-session__when">now</span>
                    <StatusIcon status={s.status} />
                  </div>
                )}
              </For>
            </div>
          )}
        </For>
        <div class="kw-side__bottom">
          <span class="kw-side__tools">
            <FolderIcon />
            <SearchIcon />
            <GearIcon />
          </span>
          <span class="kw-tally">
            <StatusIcon status="waiting" size={12} /> 1
            <StatusIcon status="working" size={12} /> 2
            <StatusIcon status="done" size={12} /> 1
          </span>
        </div>
      </aside>

      <div class="kw-main">
        <div class="kw-col">
          <Pane title="Snake demo uncommitted changes" dir="~/kero-demo/snake" program="claude" focused class="kw-pane--claude">
            <ClaudeScreen />
          </Pane>
          <Pane title="lazygit" dir="~/kero-demo/snake" program="lazygit" class="kw-pane--git">
            <LazygitScreen />
          </Pane>
        </div>
        <Pane title="snake" dir="~/kero-demo/snake" program="snake" class="kw-pane--snake">
          <SnakeScreen />
        </Pane>
      </div>
    </div>
  );
}

function Pane(props: { title: string; dir: string; program: string; focused?: boolean; class?: string; children: JSX.Element }) {
  return (
    <section class={`kw-pane ${props.class ?? ''}`} classList={{ 'is-focused': !!props.focused }}>
      <header class="kw-pane__head">
        <TermIcon />
        <span class="kw-pane__title">{props.title}</span>
        <span class="kw-pane__dir">{props.dir}</span>
        <span class="kw-pane__end">
          <span class="kw-pill">{props.program}</span>
          <Show when={props.focused}>
            <SplitRightIcon />
            <SplitDownIcon />
            <ZoomIcon />
            <CloseIcon />
          </Show>
        </span>
      </header>
      <div class="kw-term">{props.children}</div>
    </section>
  );
}

// ---------- Claude Code ----------

function ClaudeScreen() {
  return (
    <pre>
      <b>⏺</b> <b>Ran</b> <span class="c-blue">git</span> diff -- demo/snake.mjs <span class="c-blue">&&</span>{' '}
      <span class="c-blue">git</span> status <span class="c-orange">--short</span>
      {'\n'}
      <span class="c-dim">{'  ⎿  '}</span>
      <span class="c-dim">diff --git a/demo/snake.mjs b/demo/snake.mjs</span>
      {'\n'}
      <span class="c-dim">{'     +16 lines (ctrl+o to expand)\n'}</span>
      {'\n'}
      <b>⏺</b> <b>## Review summary</b>
      {'\n\n'}
      {'  The change adds '}
      <span class="c-purple">--size 32x18</span>
      {' to pick the board, turning\n'}
      {'  '}
      <span class="c-purple">WIDTH</span>
      {' and '}
      <span class="c-purple">HEIGHT</span>
      {' from consts into lets.\n\n'}
      {'  - A board of '}
      <span class="c-purple">1x1</span>
      {' passes the check and hangs the\n'}
      {'    game: '}
      <span class="c-purple">placeFood()</span>
      {' never finds a free cell.\n'}
      {'  - The header comment never mentions '}
      <span class="c-purple">--size</span>
      {'.\n\n'}
      {'  '}
      <b>Verdict:</b>
      {' close, but it needs a bounds check.\n\n'}
      <span class="c-dim">✻ Crunched for 24s</span>
      {'\n'}
      <span class="kw-rule" />
      <span class="c-dim">❯</span> <span class="kw-caret" />
      {'\n'}
      <span class="kw-rule" />
      <span class="c-amber">{'  ⏵⏵ auto mode on'}</span>
      <span class="c-dim"> (shift+tab to cycle)</span>
    </pre>
  );
}

// ---------- lazygit ----------

function Box(props: { label: string; active?: boolean; foot?: string; class?: string; children?: JSX.Element }) {
  return (
    <div class={`lg-box ${props.class ?? ''}`} classList={{ 'is-active': !!props.active }}>
      <span class="lg-box__label">{props.label}</span>
      <div class="lg-box__body">{props.children}</div>
      <Show when={props.foot}>
        <span class="lg-box__foot">{props.foot}</span>
      </Show>
    </div>
  );
}

function Fold(props: { label: string; count?: string }) {
  return (
    <div class="lg-fold">
      <span>{props.label}</span>
      <i />
      <Show when={props.count}>
        <span>{props.count}</span>
      </Show>
    </div>
  );
}

function LazygitScreen() {
  return (
    <div class="lg">
      <div class="lg-left">
        <Fold label="[1]─Status" />
        <Box label="[2]─Files - Worktree" active foot="1 of 2" class="lg-grow">
          <div class="lg-row is-selected">▼ demo</div>
          <div class="lg-row">
            {'   '}
            <span class="c-red">M</span> snake.mjs
          </div>
        </Box>
        <Fold label="[3]─Local branches" count="1 of 1" />
        <Fold label="[4]─Commits" count="1 of 1" />
        <Fold label="[5]─Stash" count="0 of 0" />
      </div>
      <div class="lg-right">
        <Box label="[0]─Unstaged changes" class="lg-grow">
          <pre>
            <b>diff --git a/demo/snake.mjs b/demo/snake.mjs</b>
            {'\n'}
            <b>index 4b34774..813341a 100644</b>
            {'\n'}
            <b>--- a/demo/snake.mjs</b>
            {'\n'}
            <b>+++ b/demo/snake.mjs</b>
            {'\n'}
            <span class="c-cyan">@@ -2,11 +2,16 @@</span>
            {'\n'}
            {' // A terminal snake. Arrow keys steer,\n'}
            {'\n'}
            <span class="c-red">{'-const WIDTH = 24;\n-const HEIGHT = 14;\n'}</span>
            <span class="c-green">
              {'+let WIDTH = 24;\n+let HEIGHT = 14;\n'}
              {"+// --size 32x18 picks the board's size.\n"}
              {"+const size = process.argv[i + 1];\n"}
            </span>
          </pre>
        </Box>
        <Box label="Command log" class="lg-log">
          <span class="c-green">files panel</span>
        </Box>
      </div>
      <div class="lg-bar">
        <span class="c-blue">Stage: &lt;space&gt; | Commit: c | Stash: s | …</span>
        <span>
          <u class="c-magenta">Donate</u> <u class="c-amber">Ask Question</u> 0.63.1
        </span>
      </div>
    </div>
  );
}

// ---------- snake ----------

const W = 24;
const H = 21;
type P = { x: number; y: number };

function createGame() {
  let seed = 23;
  const rand = () => {
    seed = (seed + 0x6d2b79f5) | 0;
    let t = Math.imul(seed ^ (seed >>> 15), 1 | seed);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
  let snake: P[] = [];
  let dir: P = { x: 1, y: 0 };
  let food: P[] = [];
  let score = 0;
  let over = 0;
  const free = (p: P) => !snake.some((s) => s.x === p.x && s.y === p.y) && !food.some((f) => f.x === p.x && f.y === p.y);
  const place = () => {
    for (let i = 0; i < 200; i++) {
      const p = { x: Math.floor(rand() * W), y: Math.floor(rand() * H) };
      if (free(p)) return food.push(p);
    }
  };
  const reset = () => {
    snake = [
      { x: 6, y: 7 },
      { x: 5, y: 7 },
      { x: 4, y: 7 },
    ];
    dir = { x: 1, y: 0 };
    food = [];
    score = 0;
    over = 0;
    while (food.length < 10) place();
  };
  const blocked = (p: P) =>
    p.x < 0 || p.y < 0 || p.x >= W || p.y >= H || snake.slice(0, -1).some((s) => s.x === p.x && s.y === p.y);
  const step = () => {
    if (over) {
      if (--over === 0) reset();
      return;
    }
    const head = snake[0];
    const target = food.reduce((b, f) =>
      Math.abs(f.x - head.x) + Math.abs(f.y - head.y) < Math.abs(b.x - head.x) + Math.abs(b.y - head.y) ? f : b,
    );
    const options = [
      { x: 1, y: 0 },
      { x: -1, y: 0 },
      { x: 0, y: 1 },
      { x: 0, y: -1 },
    ].filter((d) => !(d.x === -dir.x && d.y === -dir.y) && !blocked({ x: head.x + d.x, y: head.y + d.y }));
    if (options.length === 0) {
      over = 12;
      return;
    }
    options.sort(
      (a, b) =>
        Math.abs(head.x + a.x - target.x) + Math.abs(head.y + a.y - target.y) -
        (Math.abs(head.x + b.x - target.x) + Math.abs(head.y + b.y - target.y)),
    );
    dir = options[0];
    const next = { x: head.x + dir.x, y: head.y + dir.y };
    snake.unshift(next);
    const eaten = food.findIndex((f) => f.x === next.x && f.y === next.y);
    if (eaten >= 0) {
      food.splice(eaten, 1);
      score++;
      place();
    } else {
      snake.pop();
    }
  };
  const rows = () => {
    const out: { cls: string; ch: string }[][] = [];
    for (let y = 0; y < H; y++) {
      const row: { cls: string; ch: string }[] = [];
      for (let x = 0; x < W; x++) {
        const i = snake.findIndex((s) => s.x === x && s.y === y);
        if (i === 0) row.push({ cls: 'c-green', ch: '◆' });
        else if (i > 0) row.push({ cls: 'c-green', ch: '■' });
        else if (food.some((f) => f.x === x && f.y === y)) row.push({ cls: 'c-red', ch: '●' });
        else row.push({ cls: '', ch: ' ' });
      }
      out.push(row);
    }
    return out;
  };
  reset();
  // Start a little way into a game, the same on the server as here.
  while (score < 20) step();
  return { step, rows, score: () => score };
}

function SnakeScreen() {
  const game = createGame();
  const [frame, setFrame] = createSignal({ rows: game.rows(), score: game.score() });
  let el!: HTMLPreElement;

  onMount(() => {
    if (window.matchMedia('(prefers-reduced-motion: reduce)').matches) return;
    let timer: ReturnType<typeof setInterval> | undefined;
    const io = new IntersectionObserver(([e]) => {
      if (e.isIntersecting && !timer) {
        timer = setInterval(() => {
          game.step();
          setFrame({ rows: game.rows(), score: game.score() });
        }, 130);
      } else if (!e.isIntersecting && timer) {
        clearInterval(timer);
        timer = undefined;
      }
    });
    io.observe(el);
    onCleanup(() => {
      io.disconnect();
      if (timer) clearInterval(timer);
    });
  });

  const edge = '+' + '-'.repeat(W * 2) + '+';
  return (
    <pre ref={el}>
      <span class="c-cyan">
        S N A K E{'   '}Score: {frame().score}
      </span>
      {'\n\n'}
      <span class="c-cyan">{edge}</span>
      {'\n'}
      <For each={frame().rows}>
        {(row) => (
          <>
            <span class="c-cyan">|</span>
            <For each={row}>{(cell) => <span class={cell.cls}>{cell.ch + ' '}</span>}</For>
            <span class="c-cyan">|</span>
            {'\n'}
          </>
        )}
      </For>
      <span class="c-cyan">{edge}</span>
      {'\n\n'}
      <span class="c-dim">Autopilot · Space pause · R restart · Ctrl+C quit</span>
    </pre>
  );
}

// ---------- Icons ----------

// The app's own icons, from the repository's icons/ (Framework7 and
// Ionicons, as icons.go embeds them).

function glyph(svg: string, size = 15) {
  // The SVGs size themselves at 1em.
  return () => <span class="kw-icon" style={{ 'font-size': `${size / 16}em` }} innerHTML={svg} />;
}

const SidebarIcon = glyph(sidebarSvg, 16);
const PlusIcon = glyph(plusSvg, 14);
const FolderIcon = glyph(folderSvg, 15);
const SearchIcon = glyph(searchSvg, 14);
const GearIcon = glyph(gearSvg, 15);
const TermIcon = glyph(terminalSvg, 14);
const SplitRightIcon = glyph(splitRightSvg, 14);
const SplitDownIcon = glyph(splitDownSvg, 14);
const ZoomIcon = glyph(zoomSvg, 13);
const CloseIcon = glyph(closeSvg, 11);

// The status glyphs kero draws in code (statusIconP in view.go), with its
// light palette: a faint check once seen, a disc with a check when done
// unseen, a turning arc while working, a pulsing ring when it needs you.
function StatusIcon(props: { status: Status; size?: number }) {
  const size = () => props.size ?? 15;
  const c = () => size() / 2;
  const r = () => size() / 2 - 1;
  return (
    <svg
      class={`kw-status kw-status--${props.status}`}
      style={{ width: `${size() / 16}em`, height: `${size() / 16}em` }}
      viewBox={`0 0 ${size()} ${size()}`}
      fill="none"
      stroke-linecap="round"
      stroke-linejoin="round"
      aria-hidden="true"
    >
      {props.status === 'idle' && (
        <path
          d={`M${c() - r() * 0.62} ${c() + 0.4}L${c() - r() * 0.12} ${c() + r() * 0.5}L${c() + r() * 0.66} ${c() - r() * 0.46}`}
          stroke="#a3a3ad"
          stroke-width="1.5"
        />
      )}
      {props.status === 'done' && (
        <>
          <circle cx={c()} cy={c()} r={r() + 0.5} fill="#1d1d1f" />
          <path
            d={`M${c() - r() * 0.42} ${c() + 0.2}L${c() - r() * 0.08} ${c() + r() * 0.36}L${c() + r() * 0.46} ${c() - r() * 0.34}`}
            stroke="#fff"
            stroke-width="1.6"
          />
        </>
      )}
      {props.status === 'working' && (
        <>
          <circle cx={c()} cy={c()} r={r()} stroke="rgba(29,29,31,0.13)" stroke-width="1.7" />
          <circle
            class="kw-status__arc"
            cx={c()}
            cy={c()}
            r={r()}
            stroke="#1d1d1f"
            stroke-width="1.7"
            pathLength="100"
            stroke-dasharray="30 70"
          />
        </>
      )}
      {props.status === 'waiting' && (
        <>
          <circle cx={c()} cy={c()} r={r()} stroke="#c27b0f" stroke-width="1.7" />
          <circle class="kw-status__pulse" cx={c()} cy={c()} r={r() * 0.42} fill="#c27b0f" />
        </>
      )}
    </svg>
  );
}
