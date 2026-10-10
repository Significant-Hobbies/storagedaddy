import { spawnSync } from 'node:child_process';
import { cpSync, readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

const landing = fileURLToPath(new URL('../landing/', import.meta.url));
const result = spawnSync('npm', ['--prefix', landing, 'run', 'build'], { stdio: 'inherit' });
if (result.error) throw result.error;
if (result.status !== 0) process.exit(result.status ?? 1);

const dist = new URL('../landing/dist/', import.meta.url);
const target = new URL('../public/storagedaddy/', import.meta.url);
const html = readFileSync(new URL('index.html', dist), 'utf8');
if (!html.includes('data-fleet-footer="studio"')) {
  throw new Error('Refusing to publish landing output without StudioFooter');
}
cpSync(new URL('_astro/', dist), new URL('_astro/', target), { recursive: true });
cpSync(new URL('home/', dist), new URL('home/', target), { recursive: true });
cpSync(new URL('index.html', dist), new URL('index.html', target));
