// Records a scripted walkthrough of a preview environment, driven by the repo's tour file.
//
//   PREVIEW_URL=https://<branch>.<project>.deployment.lat TOUR=.preview/tour.json OUT_DIR=out node tour.mjs
//
// Tour file: { "viewport": {"width":1440,"height":810}, "sessions": [{ "name": "user", "steps": [
//   { "name": "landing", "visit": "/" },
//   { "name": "login", "login": "/login", "email": "user@example.dev", "password": "password" },
//   { "name": "dashboard", "visit": "/dashboard", "wait": "text=Today" }
// ]}]}
// Each session is a fresh browser context (separate cookies), recorded back to back.
// Login steps fill the first email (or text) input and password input, then submit;
// override with "emailSelector", "passwordSelector" or "submitSelector".
//
// Writes to OUT_DIR: tour.mp4, tour.gif, steps/NN-<name>.png and manifest.json.
// DEMO_CLOCK (ISO time) freezes the browser clock so relative times ("5 min ago", "today")
// render identically across commits; the demo action passes the previous run's clock.
import { chromium } from 'playwright';
import { mkdirSync, rmSync, readdirSync, readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { concatVideos, toGif } from './media.mjs';

const base = (process.env.PREVIEW_URL ?? '').replace(/\/+$/, '');
if (!base) throw new Error('PREVIEW_URL is required');
const tour = JSON.parse(readFileSync(process.env.TOUR ?? '.preview/tour.json', 'utf8'));
const out = process.env.OUT_DIR ?? 'out';
const clock = process.env.DEMO_CLOCK || new Date().toISOString();
const size = tour.viewport ?? { width: 1440, height: 810 };

rmSync(out, { recursive: true, force: true });
mkdirSync(join(out, 'steps'), { recursive: true });
mkdirSync(join(out, 'raw'), { recursive: true });

const browser = await chromium.launch({ slowMo: 150 });
const steps = [];
const failures = [];
const firstLine = (error) => String(error?.message ?? error).split('\n')[0];
const slug = (s) => s.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '');

for (const session of tour.sessions) {
  const context = await browser.newContext({
    viewport: size,
    recordVideo: { dir: join(out, 'raw', String(tour.sessions.indexOf(session))), size },
    colorScheme: session.colorScheme ?? 'light',
    reducedMotion: 'reduce',
  });
  await context.clock.setFixedTime(new Date(clock));
  const page = await context.newPage();

  const shot = async (name) => {
    await page.waitForLoadState('networkidle').catch(() => {});
    await page.waitForTimeout(1000);
    const file = `${String(steps.length + 1).padStart(2, '0')}-${slug(name)}.png`;
    await page.screenshot({ path: join(out, 'steps', file) });
    steps.push({ name, file });
    console.log(`✓ ${name}`);
  };

  for (const step of session.steps) {
    const name = step.name ?? step.visit ?? step.login;
    try {
      if (step.login) {
        await page.goto(base + step.login);
        await page.locator(step.emailSelector ?? 'input[type=email], input[type=text]').first()
          .pressSequentially(step.email, { delay: 30 });
        await page.locator(step.passwordSelector ?? 'input[type=password]').first()
          .pressSequentially(step.password, { delay: 30 });
        await shot(name);
        await page.locator(step.submitSelector ?? 'button[type=submit]').first().click();
        await page.waitForURL((u) => u.pathname !== new URL(base + step.login).pathname, { timeout: 15000 });
      } else {
        await page.goto(base + step.visit);
        if (step.wait) await page.locator(step.wait).first().waitFor({ timeout: 10000 });
        await shot(name);
      }
    } catch (error) {
      failures.push({ step: name, error: firstLine(error) });
      console.error(`✗ ${name}: ${firstLine(error)}`);
      if (step.login) break; // later steps of this session need the login
    }
  }
  await context.close(); // flushes the video
}
await browser.close();

const clips = readdirSync(join(out, 'raw')).sort()
  .flatMap((dir) => readdirSync(join(out, 'raw', dir)).map((f) => join(out, 'raw', dir, f)));
concatVideos(clips, join(out, 'tour.mp4'));
toGif(join(out, 'tour.mp4'), join(out, 'tour.gif'));
rmSync(join(out, 'raw'), { recursive: true });

writeFileSync(join(out, 'manifest.json'), JSON.stringify({
  url: base,
  sha: process.env.DEMO_SHA ?? null,
  clock,
  recordedAt: new Date().toISOString(),
  steps,
  failures,
}, null, 2));
console.log(`Tour: ${steps.length} steps, ${failures.length} failures → ${out}/tour.mp4`);
if (steps.length === 0) process.exit(1);
