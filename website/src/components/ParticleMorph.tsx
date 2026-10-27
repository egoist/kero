import { onCleanup, onMount } from 'solid-js';

// A cloud of glowing points that gathers into Kero's frog, then morphs, in
// 3D, into a prompt and back, over and over. Each morph bursts outward and
// spins the whole cloud once; the cursor scatters points, and a click skips
// to the other shape. A few points wear Kero's status colors, and the frog
// wears its own.

const SHAPES = ['frog', 'prompt'] as const;
type Shape = (typeof SHAPES)[number];

const HOLD = 3.4; // seconds a shape holds
const MORPH = 2.0; // seconds a morph takes
// Lime, then the status colors (waiting, done), then the frog's belly,
// cheeks and, dimmer so its lines stand out, its body.
const COLORS = ['#c3ec74', '#f5b84a', '#7cc7ff', '#e6dc8e', '#ff9f98', '#6f8f36'];
// Shapes drawn flat, which turn less while they hold so they face you.
const FLAT = new Set<string>(['prompt', 'frog']);

export default function ParticleMorph() {
  let host!: HTMLDivElement;
  let canvas!: HTMLCanvasElement;

  onMount(() => {
    const ctx = canvas.getContext('2d');
    if (!ctx) return;
    const reduced = window.matchMedia('(prefers-reduced-motion: reduce)').matches;

    let w = 0;
    let h = 0;
    let dpr = 1;
    const resize = () => {
      const r = host.getBoundingClientRect();
      w = r.width;
      h = r.height;
      dpr = Math.min(window.devicePixelRatio || 1, 2);
      canvas.width = Math.round(w * dpr);
      canvas.height = Math.round(h * dpr);
    };
    resize();

    const N = Math.round(Math.min(2000, Math.max(800, (w * h) / 150)));
    const rand = mulberry32(7);
    const color = new Uint8Array(N);
    const phase = new Float32Array(N);
    const delay = new Float32Array(N);
    for (let i = 0; i < N; i++) {
      const r = rand();
      color[i] = r < 0.07 ? 1 : r < 0.12 ? 2 : 0;
      phase[i] = rand() * Math.PI * 2;
      delay[i] = rand();
    }

    const sprites = COLORS.map(glowSprite);
    const targets = new Map<Shape, Float32Array>();
    // Until the icon loads, the frog is a scattered haze; until the font
    // loads, so is the prompt.
    const haze = buildHaze(N, rand);
    targets.set('frog', haze);
    targets.set('prompt', haze);
    // Each shape's colors: the frog's own once loaded, else each point's.
    const tints = new Map<Shape, Uint8Array>();
    const tintOf = (s: Shape) => tints.get(s) ?? color;

    const pos = new Float32Array(N * 3);
    const from = new Float32Array(N * 3);
    pos.set(haze);
    const ox = new Float32Array(N);
    const oy = new Float32Array(N);

    let index = 0;
    let to: Float32Array = haze;
    let fromTint: Uint8Array = color;
    let toTint: Uint8Array = color;
    let morphing = false;
    let stageStart = 0;
    let spin = 0; // completed spins, in turns
    let now = 0;
    let wobble = 0.3; // how far the cloud sways, eased per shape

    const next = () => {
      index = (index + 1) % SHAPES.length;
      from.set(pos);
      fromTint = toTint;
      to = targets.get(SHAPES[index])!;
      toTint = tintOf(SHAPES[index]);
      morphing = true;
      stageStart = now;
    };

    const mouse = { x: -1e4, y: -1e4 };
    const onMove = (e: PointerEvent) => {
      const r = canvas.getBoundingClientRect();
      mouse.x = e.clientX - r.left;
      mouse.y = e.clientY - r.top;
    };
    const onLeave = () => {
      mouse.x = mouse.y = -1e4;
    };
    const onClick = () => {
      if (!morphing) next();
    };
    canvas.addEventListener('pointermove', onMove);
    canvas.addEventListener('pointerleave', onLeave);
    canvas.addEventListener('click', onClick);

    const draw = (t: number) => {
      ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
      ctx.clearRect(0, 0, w, h);
      ctx.globalCompositeOperation = 'lighter';

      const elapsed = t - stageStart;
      let progress = 0;
      if (morphing) {
        progress = Math.min(1, elapsed / MORPH);
        if (progress >= 1) {
          morphing = false;
          stageStart = t;
          spin += 1;
          pos.set(to);
        }
      } else if (!reduced && elapsed > HOLD && tints.has('frog')) {
        next();
      }

      const turn = morphing ? easeInOut(progress) : 0;
      wobble += ((FLAT.has(SHAPES[index]) ? 0.16 : 1) - wobble) * 0.04;
      const rotY = (spin + turn) * Math.PI * 2 + 0.55 * wobble * Math.sin(t * 0.42);
      const rotX = (0.18 + 0.22 * Math.sin(t * 0.31)) * wobble;
      const cy = Math.cos(rotY);
      const sy = Math.sin(rotY);
      const cx = Math.cos(rotX);
      const sx = Math.sin(rotX);
      const S = Math.min(w, h) * 0.34;
      const fov = 3.4;
      const midX = w / 2;
      const midY = h / 2;
      const R = 90;

      for (let i = 0; i < N; i++) {
        const k = i * 3;
        let x: number;
        let y: number;
        let z: number;
        let tint = toTint[i];
        if (morphing) {
          // Each point leaves on its own beat, bursts out and swirls in.
          const local = clamp01((progress - delay[i] * 0.35) / 0.65);
          const e = easeInOut(local);
          const burst = Math.sin(Math.PI * e);
          if (e < 0.5) tint = fromTint[i];
          x = from[k] + (to[k] - from[k]) * e;
          y = from[k + 1] + (to[k + 1] - from[k + 1]) * e;
          z = from[k + 2] + (to[k + 2] - from[k + 2]) * e;
          const len = Math.hypot(x, y, z) || 1;
          const push = burst * (0.45 + 0.5 * delay[i]);
          x += (x / len) * push;
          y += (y / len) * push;
          z += (z / len) * push;
          const a = burst * (1.2 + delay[i]);
          const ca = Math.cos(a);
          const sa = Math.sin(a);
          const nx = x * ca - z * sa;
          z = x * sa + z * ca;
          x = nx;
          pos[k] = x;
          pos[k + 1] = y;
          pos[k + 2] = z;
        } else {
          x = to[k];
          y = to[k + 1];
          z = to[k + 2];
        }
        // Breathing.
        const b = 0.014 * Math.sin(t * 1.4 + phase[i]);
        x += b;
        y += 0.014 * Math.cos(t * 1.1 + phase[i]);

        // Rotate: around Y, then X.
        const x1 = x * cy - z * sy;
        const z1 = x * sy + z * cy;
        const y2 = y * cx - z1 * sx;
        const z2 = y * sx + z1 * cx;

        const scale = fov / (fov + z2);
        let px = midX + x1 * S * scale;
        let py = midY + y2 * S * scale;

        const dx = px - mouse.x;
        const dy = py - mouse.y;
        const d2 = dx * dx + dy * dy;
        if (d2 < R * R) {
          const d = Math.sqrt(d2) || 1;
          const f = (1 - d / R) * 5;
          ox[i] += (dx / d) * f;
          oy[i] += (dy / d) * f;
        }
        ox[i] *= 0.9;
        oy[i] *= 0.9;
        px += ox[i];
        py += oy[i];

        const depth = clamp01((z2 + 1.4) / 2.8);
        ctx.globalAlpha = 0.25 + 0.75 * (1 - depth);
        const size = (tint === 1 || tint === 2 ? 7 : tint >= 3 ? 4.6 : 5.5) * scale * scale;
        ctx.drawImage(sprites[tint], px - size / 2, py - size / 2, size, size);
      }
      ctx.globalAlpha = 1;
      ctx.globalCompositeOperation = 'source-over';
    };

    let raf = 0;
    let running = false;
    let last = performance.now();
    const loop = (ms: number) => {
      now += Math.min(0.05, (ms - last) / 1000);
      last = ms;
      draw(now);
      raf = requestAnimationFrame(loop);
    };
    const start = () => {
      if (running || reduced) return;
      running = true;
      last = performance.now();
      raf = requestAnimationFrame(loop);
    };
    const stop = () => {
      running = false;
      cancelAnimationFrame(raf);
    };

    // Only animate while it shows.
    let visible = true;
    const io = new IntersectionObserver(([entry]) => {
      visible = entry.isIntersecting;
      visible && !document.hidden ? start() : stop();
    });
    io.observe(host);
    const onVisibility = () => (visible && !document.hidden ? start() : stop());
    document.addEventListener('visibilitychange', onVisibility);
    const ro = new ResizeObserver(() => {
      resize();
      if (!running) draw(now);
    });
    ro.observe(host);

    document.fonts
      .load('800 180px "Geist Mono Variable"')
      .catch(() => {})
      .then(() => {
        const prompt = buildPrompt(N, rand);
        targets.set('prompt', prompt);
        if (SHAPES[index] === 'prompt') {
          from.set(pos);
          to = prompt;
          morphing = true;
          stageStart = now;
        }
      });

    const icon = new Image();
    icon.onload = () => {
      const frog = buildFrog(icon, N, rand);
      if (!frog) return;
      targets.set('frog', frog.points);
      tints.set('frog', frog.tints);
      if (reduced) {
        // Without motion, the frog stands still.
        pos.set(frog.points);
        to = frog.points;
        toTint = frog.tints;
        morphing = false;
        draw(0);
        return;
      }
      if (SHAPES[index] === 'frog') {
        to = frog.points;
        toTint = frog.tints;
        if (!morphing) {
          from.set(pos);
          fromTint = color;
          morphing = true;
          stageStart = now;
        }
      }
    };
    icon.src = '/icon.png';

    draw(0);
    start();

    onCleanup(() => {
      stop();
      io.disconnect();
      ro.disconnect();
      document.removeEventListener('visibilitychange', onVisibility);
      canvas.removeEventListener('pointermove', onMove);
      canvas.removeEventListener('pointerleave', onLeave);
      canvas.removeEventListener('click', onClick);
    });
  });

  return (
    <div class="morph" ref={host} aria-hidden="true">
      <canvas ref={canvas} />
    </div>
  );
}

// ---------- Shapes, each about a unit in radius ----------

// A haze of points scattered through a ball, which the frog gathers from.
function buildHaze(n: number, rand: () => number) {
  const out = new Float32Array(n * 3);
  for (let i = 0; i < n; i++) {
    // Uniform in a ball: a random direction, a radius by the cube root.
    const u = rand() * 2 - 1;
    const a = rand() * Math.PI * 2;
    const r = 1.5 * Math.cbrt(rand());
    const q = Math.sqrt(1 - u * u);
    out[i * 3] = r * q * Math.cos(a);
    out[i * 3 + 1] = r * u;
    out[i * 3 + 2] = r * q * Math.sin(a);
  }
  return out;
}

// The prompt, ">_", sampled from type drawn off screen.
function buildPrompt(n: number, rand: () => number) {
  const W = 420;
  const H = 240;
  const c = document.createElement('canvas');
  c.width = W;
  c.height = H;
  const g = c.getContext('2d')!;
  g.fillStyle = '#fff';
  g.textAlign = 'center';
  g.textBaseline = 'middle';
  g.font = '800 200px "Geist Mono Variable", ui-monospace, monospace';
  g.fillText('>_', W / 2, H / 2 + 6);
  const data = g.getImageData(0, 0, W, H).data;
  const pts: number[] = [];
  for (let y = 0; y < H; y += 2) {
    for (let x = 0; x < W; x += 2) {
      if (data[(y * W + x) * 4 + 3] > 140) pts.push(x, y);
    }
  }
  const out = new Float32Array(n * 3);
  const count = pts.length / 2;
  for (let i = 0; i < n; i++) {
    const j = Math.floor(rand() * count) * 2;
    out[i * 3] = ((pts[j] - W / 2) / (W / 2)) * 1.2 + (rand() - 0.5) * 0.01;
    out[i * 3 + 1] = ((pts[j + 1] - H / 2) / (W / 2)) * 1.2;
    out[i * 3 + 2] = (rand() - 0.5) * 0.22;
  }
  return out;
}

// The frog of Kero's icon, as a line drawing in light: the outline of its
// silhouette, its eyes and its mouth in bright lime, where most points go;
// its body dim, its belly and cheeks in their colors. The eyes stay dark
// inside their rims, as in the icon.
function buildFrog(img: HTMLImageElement, n: number, rand: () => number) {
  const size = 256;
  const c = document.createElement('canvas');
  c.width = c.height = size;
  const g = c.getContext('2d', { willReadFrequently: true });
  if (!g) return null;
  g.drawImage(img, 0, 0, size, size);
  // The frog sits in the icon's lower right.
  const x0 = Math.round(size * 0.32);
  const y0 = Math.round(size * 0.43);
  const cw = Math.round(size * 0.92) - x0;
  const ch = Math.round(size * 0.92) - y0;
  const data = g.getImageData(x0, y0, cw, ch).data;

  // Each pixel: 0 dark, 1 body, 3 belly, 4 cheek.
  const kind = new Uint8Array(cw * ch);
  for (let i = 0; i < cw * ch; i++) {
    const r = data[i * 4];
    const gr = data[i * 4 + 1];
    const b = data[i * 4 + 2];
    const a = data[i * 4 + 3];
    if (a < 200 || 0.299 * r + 0.587 * gr + 0.114 * b < 110) continue;
    kind[i] = r - gr > 35 ? 4 : r > 232 && b > 135 ? 3 : 1;
  }
  // A dark pixel next to a light one is a line: the outline, an eye's rim,
  // the mouth.
  const lit = (x: number, y: number) => x >= 0 && y >= 0 && x < cw && y < ch && kind[y * cw + x] !== 0;
  const pts: number[] = [];
  const tint: number[] = [];
  const add = (x: number, y: number, t: number, times: number) => {
    for (let k = 0; k < times; k++) {
      pts.push(x, y);
      tint.push(t);
    }
  };
  for (let y = 0; y < ch; y++) {
    for (let x = 0; x < cw; x++) {
      const k = kind[y * cw + x];
      if (k === 0) {
        if (lit(x - 1, y) || lit(x + 1, y) || lit(x, y - 1) || lit(x, y + 1) || lit(x - 2, y) || lit(x + 2, y) || lit(x, y - 2) || lit(x, y + 2)) {
          add(x, y, 0, 6);
        }
      } else if (k === 1) {
        if ((x + y) % 3 === 0) add(x, y, 5, 1);
      } else if (k === 3) {
        if ((x + y) % 2 === 0) add(x, y, 3, 1);
      } else {
        add(x, y, 4, 3);
      }
    }
  }
  if (pts.length === 0) return null;

  const half = Math.max(cw, ch) / 2;
  const points = new Float32Array(n * 3);
  const tints = new Uint8Array(n);
  const count = tint.length;
  for (let i = 0; i < n; i++) {
    const j = Math.floor(rand() * count);
    const x = ((pts[j * 2] - cw / 2) / half) * 1.4;
    const y = ((pts[j * 2 + 1] - ch / 2) / half) * 1.4;
    points[i * 3] = x;
    points[i * 3 + 1] = y;
    points[i * 3 + 2] = -0.3 * Math.sqrt(Math.max(0, 1 - (x * x + y * y) / 2)) + (rand() - 0.5) * 0.02;
    tints[i] = tint[j];
  }
  return { points, tints };
}

// ---------- Helpers ----------

function glowSprite(color: string) {
  const size = 64;
  const c = document.createElement('canvas');
  c.width = c.height = size;
  const g = c.getContext('2d')!;
  const grad = g.createRadialGradient(size / 2, size / 2, 0, size / 2, size / 2, size / 2);
  grad.addColorStop(0, '#ffffff');
  grad.addColorStop(0.18, color);
  grad.addColorStop(0.45, color + '55');
  grad.addColorStop(1, color + '00');
  g.fillStyle = grad;
  g.fillRect(0, 0, size, size);
  return c;
}

function easeInOut(t: number) {
  return t < 0.5 ? 4 * t * t * t : 1 - Math.pow(-2 * t + 2, 3) / 2;
}

function clamp01(t: number) {
  return t < 0 ? 0 : t > 1 ? 1 : t;
}

// A small seeded random, so the cloud is the same on every load.
function mulberry32(seed: number) {
  return () => {
    seed |= 0;
    seed = (seed + 0x6d2b79f5) | 0;
    let t = Math.imul(seed ^ (seed >>> 15), 1 | seed);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}
