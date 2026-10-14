// Host verification for #861. Run only with explicit real-machine authorization.
import { mkdir, stat, copyFile } from 'node:fs/promises';
import { spawn, execFile } from 'node:child_process';
import { promisify } from 'node:util';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

const run = promisify(execFile);
const [kind, output, playwrightRoot] = process.argv.slice(2);
await mkdir(output, { recursive: true });
const target = path.join(output, kind === 'chrome' ? 'chrome.webm' : 'simulator.mp4');
if (kind === 'chrome') {
  // Keep both the package and its video encoder in the temporary recording environment.
  process.env.PLAYWRIGHT_BROWSERS_PATH = path.join(playwrightRoot, 'browsers');
  const { chromium } = await import(
    pathToFileURL(path.join(playwrightRoot, 'node_modules/playwright/index.mjs'))
  );
  const browser = await chromium.launch({
    executablePath: '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
  });
  try {
    const context = await browser.newContext({
      recordVideo: { dir: output },
      viewport: { width: 800, height: 600 },
    });
    const page = await context.newPage();
    await page.setContent('<h1>vibing.nvim native approval recording</h1><p>Chrome on macOS</p>');
    await page.waitForTimeout(3000);
    const video = page.video();
    await context.close();
    await copyFile(await video.path(), target);
  } finally {
    await browser.close();
  }
} else if (kind === 'simulator') {
  const simctl = (...args) => run('xcrun', ['simctl', ...args], { timeout: 120000 });
  const runtimes = JSON.parse((await simctl('list', 'runtimes', '--json')).stdout).runtimes;
  const runtime = runtimes.find((item) => item.isAvailable && item.name.startsWith('iOS'));
  if (!runtime) throw new Error('No available iOS runtime');
  const types = JSON.parse((await simctl('list', 'devicetypes', '--json')).stdout).devicetypes;
  const deviceType =
    types.find((item) => item.name === 'iPhone 17') ??
    types.filter((item) => item.name.startsWith('iPhone')).at(-1);
  if (!deviceType) throw new Error('No iPhone device type');
  const device = (
    await simctl('create', 'vibing-issue861-recording', deviceType.identifier, runtime.identifier)
  ).stdout.trim();
  try {
    await simctl('boot', device);
    await simctl('bootstatus', device, '-b');
    const recording = spawn('xcrun', ['simctl', 'io', device, 'recordVideo', target], {
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    let detail = '';
    let timer;
    const observe = (chunk) => {
      detail += chunk;
      // A cold simctl can take longer than five seconds merely to start recording.
      if (!timer && /Recording started/i.test(detail)) {
        timer = setTimeout(() => recording.kill('SIGINT'), 5000);
      }
    };
    recording.stderr.on('data', observe);
    recording.stdout.on('data', observe);
    const startup = setTimeout(() => recording.kill('SIGINT'), 60000);
    await new Promise((resolve, reject) => {
      recording.on('error', reject);
      recording.on('exit', (code, signal) =>
        timer && (code === 0 || signal === 'SIGINT')
          ? resolve()
          : reject(new Error(`recordVideo exited ${code}/${signal}: ${detail}`))
      );
    }).finally(() => {
      clearTimeout(timer);
      clearTimeout(startup);
    });
  } finally {
    await simctl('shutdown', device).catch(() => {});
    await simctl('delete', device);
  }
} else {
  throw new Error('Expected chrome or simulator');
}
const info = await stat(target);
if (info.size === 0) throw new Error('Recording is empty');
console.log(JSON.stringify({ kind, path: target, bytes: info.size }));
