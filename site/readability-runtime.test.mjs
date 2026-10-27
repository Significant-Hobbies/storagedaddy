import assert from 'node:assert/strict';
import test from 'node:test';
import { spawn } from 'node:child_process';
import { createServer } from 'node:net';

async function freePort() {
  const socket = createServer();
  await new Promise((resolve) => socket.listen(0, '127.0.0.1', resolve));
  const port = socket.address().port;
  await new Promise((resolve) => socket.close(resolve));
  return port;
}

for (const product of ['storagedaddy']) {
  test(`${product}: actual Worker assets and middleware honor public Markdown contract`, { timeout: 60000 }, async () => {
    const port = await freePort();
    const inspectorPort = await freePort();
    const origin = `http://127.0.0.1:${port}`;
    const server = spawn(process.execPath, ['node_modules/wrangler/bin/wrangler.js', 'dev', '--local', '--local-upstream', 'storage.daddyrad.com', '--ip', '127.0.0.1', '--port', String(port), '--inspector-port', String(inspectorPort), '--log-level', 'info'], { detached: true, stdio: ['ignore', 'pipe', 'pipe'] });
    let logs = '';
    server.stdout.on('data', (chunk) => { logs += chunk; });
    server.stderr.on('data', (chunk) => { logs += chunk; });
    try {
      let ready = false;
      for (let n = 0; n < 200; n++) {
        try { const response = await fetch(`${origin}/robots.txt`); logs += `probe ${response.status} ${response.url}\n`; ready = true; break; } catch (error) { if (n === 0 || n === 199) logs += `probe failed: ${error.message} ${error.cause?.message || ''}\n`; }
        if (server.exitCode !== null) break;
        await new Promise((resolve) => setTimeout(resolve, 200));
      }
      assert.ok(ready, logs);
      const catalogResponse = await fetch(`${origin}/api/md/_catalog`);
      assert.equal(catalogResponse.status, 200);
      const catalog = await catalogResponse.json();
      const samples = [catalog.find((route) => route.path === '/'), catalog.find((route) => route.path === '/privacy/'), catalog.find((route) => route.path.startsWith('/blog/') && route.path !== '/blog/'), catalog.find((route) => route.path === '/changelog')].filter(Boolean);
      for (const route of samples) {
        const mdPath = new URL(route.md).pathname;
        const directPath = `/api/md${route.path}`;
        const htmlPage = await fetch(origin + route.path);
        assert.equal(htmlPage.status, 200);
        assert.match(htmlPage.headers.get('content-type'), /text\/html/);
        const suffix = await fetch(origin + mdPath);
        const text = await suffix.text();
        assert.equal(suffix.status, 200);
        assert.match(suffix.headers.get('content-type'), /^text\/markdown/);
        // Wrangler's local proxy can rewrite URL-valued response headers to its origin.
        assert.ok([route.url, origin + new URL(route.url).pathname].includes(suffix.headers.get('content-location')));
        assert.ok(text.includes(route.url));
        assert.match(suffix.headers.get('link'), /rel="canonical"/);
        assert.equal(suffix.headers.get('x-robots-tag'), 'noindex, follow');
        assert.equal(suffix.headers.get('access-control-allow-origin'), '*');
        assert.ok(Number(suffix.headers.get('x-markdown-tokens')) > 0);
        assert.ok(text.startsWith('# '));
        for (const [path, accept] of [[directPath, undefined], [route.path, 'text/markdown']]) {
          const response = await fetch(origin + path, { headers: accept ? { accept } : {} });
          assert.equal(response.status, 200);
          assert.equal(await response.text(), text);
        }
        const head = await fetch(origin + mdPath, { method: 'HEAD' });
        assert.equal(await head.text(), '');
        for (const name of ['content-type', 'content-location', 'x-markdown-tokens', 'x-robots-tag']) assert.equal(head.headers.get(name), suffix.headers.get(name));
        const preflight = await fetch(origin + directPath, { method: 'OPTIONS' });
        assert.equal(preflight.status, 204);
        assert.match(preflight.headers.get('access-control-allow-methods'), /GET, HEAD, OPTIONS/);
      }
      for (const accept of ['*/*', 'text/markdown;q=0', 'text/markdown;q=0.5, text/html;q=1', 'text/markdown, text/html']) {
        const html = await fetch(origin + '/', { headers: { accept } });
        assert.match(html.headers.get('content-type'), /text\/html/);
        assert.match(html.headers.get('link'), /llms-full.txt/);
      }
      for (const path of ['/missing.md', '/api/md/admin', '/api/md/dashboard', '/api/md/missing']) {
        const missing = await fetch(origin + path);
        assert.equal(missing.status, 404);
        assert.match(missing.headers.get('content-type'), /text\/markdown/);
      }
      const full = await (await fetch(origin + '/llms-full.txt')).text();
      assert.ok(full.length < 500000);
      const policy = await (await fetch(origin + '/ai.txt')).text();
      assert.ok(policy.includes('training: allowed on public pages only'));
      const robots = await (await fetch(origin + '/robots.txt')).text();
      for (const bot of ['GPTBot', 'ClaudeBot', 'Google-Extended', 'Applebot-Extended', 'CCBot', 'Bytespider']) assert.ok(robots.includes(`User-agent: ${bot}\nAllow: /`));
      console.log(JSON.stringify({ product, routes: catalog.length, sampledRoutes: samples.map((route) => route.path), fullCharacters: full.length }));
    } finally {
      try { process.kill(-server.pid, 'SIGTERM'); } catch {}
      await new Promise((resolve) => { if (server.exitCode !== null) resolve(); else server.once('exit', resolve); });
    }
  });
}
