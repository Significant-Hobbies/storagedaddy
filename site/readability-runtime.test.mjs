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
  test(`${product}: actual Worker redirects marketing while retaining Markdown APIs and release assets`, { timeout: 60000 }, async () => {
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
        try { const response = await fetch(`${origin}/api/md/_catalog`); logs += `probe ${response.status} ${response.url}\n`; ready = true; break; } catch (error) { if (n === 0 || n === 199) logs += `probe failed: ${error.message} ${error.cause?.message || ''}\n`; }
        if (server.exitCode !== null) break;
        await new Promise((resolve) => setTimeout(resolve, 200));
      }
      assert.ok(ready, logs);
      const catalogResponse = await fetch(`${origin}/api/md/_catalog`);
      assert.equal(catalogResponse.status, 200);
      const catalog = await catalogResponse.json();
      const query = '?keep=a%2Fb&source=legacy';
      for (const [path, target] of [['/', '/'], ['/index.md', '/index.md'], ['/release', '/release/'], ['/robots.txt', '/robots.txt'], ['/llms-full.txt', '/llms-full.txt']]) {
        for (const method of ['GET', 'HEAD']) {
          const response = await fetch(origin + path + query, { method, redirect: 'manual' });
          assert.equal(response.status, 308);
          assert.equal(response.headers.get('location'), 'https://daddyrad.com/storage' + target + query);
        }
      }
      const direct = await fetch(origin + '/api/md');
      const text = await direct.text();
      assert.equal(direct.status, 200);
      assert.match(direct.headers.get('content-type'), /^text\/markdown/);
      assert.match(direct.headers.get('link'), /rel="canonical"/);
      assert.equal(direct.headers.get('x-robots-tag'), 'noindex, follow');
      assert.equal(direct.headers.get('access-control-allow-origin'), '*');
      assert.ok(Number(direct.headers.get('x-markdown-tokens')) > 0);
      assert.ok(text.startsWith('# '));
      assert.ok(text.includes('https://storage.daddyrad.com/download'));
      assert.equal(catalog.length, 1);
      assert.equal(catalog[0].url, 'https://storage.daddyrad.com/');
      const head = await fetch(origin + '/api/md', { method: 'HEAD' });
      assert.equal(await head.text(), '');
      for (const name of ['content-type', 'x-markdown-tokens', 'x-robots-tag']) assert.equal(head.headers.get(name), direct.headers.get(name));
      const preflight = await fetch(origin + '/api/md', { method: 'OPTIONS' });
      assert.equal(preflight.status, 204);
      assert.match(preflight.headers.get('access-control-allow-methods'), /GET, HEAD, OPTIONS/);
      for (const path of ['/missing.md', '/api/md/admin', '/api/md/dashboard', '/api/md/missing']) {
        const missing = await fetch(origin + path, { redirect: 'manual' });
        assert.equal(missing.status, 404);
        assert.match(missing.headers.get('content-type'), /text\/markdown/);
      }
      const metadataResponse = await fetch(origin + '/release.json', { redirect: 'manual' });
      assert.equal(metadataResponse.status, 200);
      const metadata = await metadataResponse.json();
      assert.equal(metadata.downloadUrl, 'https://storage.daddyrad.com/download');
      for (const path of ['/download', '/updates/appcast.xml']) {
        const response = await fetch(origin + path, { method: 'HEAD', redirect: 'manual' });
        assert.equal(response.status, 200);
        assert.equal(response.headers.get('location'), null);
      }
      console.log(JSON.stringify({ product, routes: catalog.length, markdownCharacters: text.length }));
    } finally {
      try { process.kill(-server.pid, 'SIGTERM'); } catch {}
      await new Promise((resolve) => { if (server.exitCode !== null) resolve(); else server.once('exit', resolve); });
    }
  });
}
