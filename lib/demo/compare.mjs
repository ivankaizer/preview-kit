// Compares two tour runs step by step and renders what changed.
//
//   BEFORE_DIR=prev AFTER_DIR=out node compare.mjs
//
// Writes AFTER_DIR/changes.json, and when anything changed: changes/NN-<step>.png
// (before | after with changed pixels highlighted), changes.mp4 and changes.gif.
import { chromium } from 'playwright';
import pixelmatch from 'pixelmatch';
import { PNG } from 'pngjs';
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { slideshow, toGif } from './media.mjs';

const beforeDir = resolve(process.env.BEFORE_DIR ?? 'prev');
const afterDir = resolve(process.env.AFTER_DIR ?? 'out');
// Share of pixels that must differ before a step counts as changed; absorbs anti-aliasing noise.
const MIN_CHANGED = Number(process.env.MIN_CHANGED ?? 0.002);

const before = JSON.parse(readFileSync(join(beforeDir, 'manifest.json'), 'utf8'));
const after = JSON.parse(readFileSync(join(afterDir, 'manifest.json'), 'utf8'));
const beforeSteps = new Map(before.steps.map((s) => [s.name, s]));
const afterNames = new Set(after.steps.map((s) => s.name));

const changesDir = join(afterDir, 'changes');
mkdirSync(changesDir, { recursive: true });

const changed = [];
const unchanged = [];
for (const step of after.steps) {
  const prev = beforeSteps.get(step.name);
  if (!prev) continue;
  const a = PNG.sync.read(readFileSync(join(beforeDir, 'steps', prev.file)));
  const b = PNG.sync.read(readFileSync(join(afterDir, 'steps', step.file)));
  if (a.width !== b.width || a.height !== b.height) {
    changed.push({ name: step.name, ratio: 1, before: prev.file, after: step.file, diff: null });
    continue;
  }
  const diff = new PNG({ width: a.width, height: a.height });
  const pixels = pixelmatch(a.data, b.data, diff.data, a.width, a.height,
    { threshold: 0.1, includeAA: false, diffMask: true, diffColor: [255, 0, 80] });
  const ratio = pixels / (a.width * a.height);
  if (ratio < MIN_CHANGED) {
    unchanged.push(step.name);
    continue;
  }
  const diffFile = `diff-${step.file}`;
  writeFileSync(join(changesDir, diffFile), PNG.sync.write(diff));
  changed.push({ name: step.name, ratio, before: prev.file, after: step.file, diff: diffFile });
}
const added = after.steps.filter((s) => !beforeSteps.has(s.name)).map((s) => s.name);
const removed = before.steps.filter((s) => !afterNames.has(s.name)).map((s) => s.name);

const short = (sha) => (sha ?? 'previous').slice(0, 7);
const frames = [];
if (changed.length) {
  const browser = await chromium.launch();
  const page = await browser.newPage({ viewport: { width: 2000, height: 640 }, deviceScaleFactor: 1 });
  // setContent pages cannot load file:// URLs, so images are inlined.
  const src = (dir, file) => `data:image/png;base64,${readFileSync(join(dir, file)).toString('base64')}`;

  for (const [i, c] of changed.entries()) {
    for (const highlight of [false, true]) {
      const overlay = highlight && c.diff
        ? `<img class="mask" src="${src(changesDir, c.diff)}">` : '';
      await page.setContent(`<!doctype html><html><head><style>
        body { margin: 0; background: #0f172a; font: 600 22px system-ui, sans-serif; color: #e2e8f0; }
        header { padding: 18px 28px 0; display: flex; justify-content: space-between; }
        header small { color: #94a3b8; font-weight: 500; }
        main { display: flex; gap: 24px; padding: 16px 28px 28px; }
        figure { margin: 0; flex: 1; }
        figcaption { margin-bottom: 8px; font-size: 18px; color: #94a3b8; }
        figcaption b { color: #e2e8f0; }
        .frame { position: relative; border-radius: 10px; overflow: hidden; outline: 2px solid #334155; }
        .frame img { display: block; width: 100%; }
        .mask { position: absolute; inset: 0; opacity: .65; }
      </style></head><body>
        <header><span>${c.name}</span><small>${(c.ratio * 100).toFixed(1)}% of pixels changed · ${i + 1}/${changed.length}</small></header>
        <main>
          <figure><figcaption><b>Before</b> · ${short(before.sha)}</figcaption>
            <div class="frame"><img src="${src(beforeDir + '/steps', c.before)}"></div></figure>
          <figure><figcaption><b>After</b> · ${short(after.sha)}${highlight ? ' · changes highlighted' : ''}</figcaption>
            <div class="frame"><img src="${src(afterDir + '/steps', c.after)}">${overlay}</div></figure>
        </main></body></html>`, { waitUntil: 'load' });
      const file = join(changesDir, `${String(i + 1).padStart(2, '0')}-${c.name}${highlight ? '' : '-plain'}.png`);
      await page.screenshot({ path: file, fullPage: true });
      frames.push(file);
      if (highlight) c.image = `changes/${String(i + 1).padStart(2, '0')}-${c.name}.png`;
    }
  }
  await browser.close();
  slideshow(frames, join(afterDir, 'changes.mp4'), { seconds: 2.5 });
  toGif(join(afterDir, 'changes.mp4'), join(afterDir, 'changes.gif'), { width: 960, fps: 2 });
}

const summary = {
  before: before.sha, after: after.sha,
  changed: changed.map(({ name, ratio, image }) => ({ name, ratio, image })),
  unchanged, added, removed,
};
writeFileSync(join(afterDir, 'changes.json'), JSON.stringify(summary, null, 2));
console.log(`Changed: ${changed.map((c) => c.name).join(', ') || 'none'}; added: ${added.join(', ') || 'none'}; removed: ${removed.join(', ') || 'none'}`);
if (!existsSync(join(afterDir, 'changes.mp4')) && changed.length) process.exit(1);
