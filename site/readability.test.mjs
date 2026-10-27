import test from 'node:test';
import assert from 'node:assert/strict';
import worker from './worker.mjs';
const origin = 'https://storage.daddyrad.com';
const env = { ASSETS: { fetch: async () => new Response('<main>Existing site</main>', { headers: { 'Content-Type': 'text/html' } }) }, DOWNLOADS: { writeDataPoint() {} } };
const fetch = (path, options) => worker.fetch(new Request(origin + path, options), env);
test('public homepage has one complete canonical mirror and source-backed discovery', async () => {
  const suffix = await fetch('/index.md');
  const body = await suffix.text();
  assert.equal(suffix.headers.get('content-location'), origin + '/');
  assert.match(body, /Canonical HTML: https:\/\/storage.daddyrad.com\//);
  assert.match(body, /https:\/\/storage.daddyrad.com\/download/);
  assert.match(body, /## /);
  for (const [path, headers] of [['/api/md', {}], ['/', { accept: 'text/markdown' }]]) {
    const response = await fetch(path, { headers });
    assert.equal(await response.text(), body);
    assert.equal(response.headers.get('x-robots-tag'), 'noindex, follow');
    assert.equal(response.headers.get('access-control-allow-origin'), '*');
    assert.match(response.headers.get('link'), /canonical/);
  }
  const catalog = await (await fetch('/api/md/_catalog')).json(); assert.equal(catalog.length, 1);
  const full = await (await fetch('/llms-full.txt')).text(); assert.match(full, /Included 1 of 1/);
  for (const name of ['GPTBot', 'ClaudeBot', 'Google-Extended', 'Applebot-Extended', 'CCBot', 'Bytespider']) assert.ok((await (await fetch('/robots.txt')).text()).includes(`User-agent: ${name}\nAllow: /`));
});
test('HTML, cache negotiation, HEAD and private route recovery preserve boundaries', async () => {
  for (const accept of ['*/*', 'text/markdown;q=0', 'text/markdown, text/html']) {
    const response = await fetch('/', { headers: { accept } });
    assert.equal(await response.text(), '<main>Existing site</main>');
    assert.match(response.headers.get('vary'), /Accept/);
  }
  const head = await fetch('/index.md', { method: 'HEAD' }); assert.equal(await head.text(), '');
  const options = await fetch('/api/md', { method: 'OPTIONS' }); assert.equal(options.status, 204);
  for (const path of ['/unknown.md', '/api/md/admin', '/api/md/dashboard']) assert.equal((await fetch(path)).status, 404);
});

test('unknown Markdown paths cannot advertise off-origin canonicals', async () => {
  const { createAgentSurfaceManifest } = await import('./agent-surfaces/manifest.mjs');
  const { createAgentSurfaceHandler } = await import('./agent-surfaces/handler.mjs');
  const fixtureOrigin = 'https://public.example';
  const manifest = createAgentSurfaceManifest({ name: 'Public fixture', url: fixtureOrigin, summary: 'Public fixture', pages: { '/': '# Public' } });
  const handler = createAgentSurfaceHandler({ manifest });
  for (const path of ['/api/md//evil.example/x', '//evil.example/x.md']) {
    const response = await handler(new Request(fixtureOrigin + path));
    assert.equal(response.status, 404);
    assert.equal(response.headers.get('content-location'), fixtureOrigin + '//evil.example/x');
    assert.equal(response.headers.get('cache-control'), 'no-store');
    assert.equal(response.headers.get('x-robots-tag'), 'noindex, follow');
    assert.ok(response.headers.get('link').includes(fixtureOrigin + '/llms.txt'));
  }
});
