import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import worker from './worker.mjs';
import release from './release.json' with { type: 'json' };
function env(status = 200) {
  const events = []; const requested = [];
  return { events, requested, DOWNLOADS: { writeDataPoint(point) { events.push(point); } }, ASSETS: { async fetch(request) { requested.push(request.url); return new Response('fixture', { status }); } } };
}
test('download serves exact release with attachment, no query forwarding or client identifiers', async () => {
 const e = env(); const response = await worker.fetch(new Request('https://storage.daddyrad.com/download?email=private', { headers: {'CF-Connecting-IP':'127.0.0.1'} }), e);
 assert.equal(response.status,200); assert.match(response.headers.get('content-disposition'), /attachment/);
 assert.equal(new URL(e.requested[0]).pathname,release.path); assert.equal(new URL(e.requested[0]).search,'');
 assert.deepEqual(e.events,[{indexes:['storagedaddy'],blobs:['download_request',release.version],doubles:[1]}]);
});
test('HEAD, range requests and missing downloads are not counted', async () => {
 for (const request of [new Request('https://storage.daddyrad.com/download',{method:'HEAD'}), new Request('https://storage.daddyrad.com/download',{headers:{Range:'bytes=0-15'}})]) {
  const e=env(); await worker.fetch(request,e); assert.equal(e.events.length,0);
 }
 const e=env(404); const response=await worker.fetch(new Request('https://storage.daddyrad.com/download'),e); assert.equal(response.status,404); assert.equal(e.events.length,0);
});
test('root landing and relative assets map to packaged assets without duplicate events', async () => {
 const e=env();
 const response=await worker.fetch(new Request('https://storage.daddyrad.com/'),e);
 await worker.fetch(new Request('https://storage.daddyrad.com/style.css'),e);
 assert.deepEqual(e.requested.map(u=>new URL(u).pathname),['/storagedaddy/','/storagedaddy/style.css']);
 assert.equal(e.events.length,1); assert.equal(e.events[0].blobs[0],'page_view');
 assert.match(response.headers.get('content-security-policy'), /https:\/\/\*\.clarity\.ms/);
 assert.match(response.headers.get('content-security-policy'), /https:\/\/c\.bing\.com/);
 assert.match(response.headers.get('content-security-policy'), /script-src[^;]*https:\/\/static\.cloudflareinsights\.com/);
 assert.match(response.headers.get('content-security-policy'), /connect-src[^;]*https:\/\/cloudflareinsights\.com/);
  assert.match(response.headers.get('content-security-policy'), /connect-src[^;]*https:\/\/api\.sassmaker\.com/);
});
test('same-origin footer artwork and fonts use the existing static route with self-only font policy', async () => {
 for (const path of ['/footer-art/storagedaddy.webp', '/fonts/fleet-footer-precise-v1/geist.woff2']) {
  for (const method of ['GET', 'HEAD']) {
   const e = env();
   const response = await worker.fetch(new Request(`https://storage.daddyrad.com${path}`, { method }), e);
   assert.equal(response.status, 200);
   assert.equal(new URL(e.requested[0]).pathname, `/storagedaddy${path}`);
   assert.match(response.headers.get('content-security-policy'), /font-src 'self'/);
   assert.equal(e.events.length, 0);
  }
 }
});
test('footer assets are packaged under the Worker asset prefix with recorded source hashes', async () => {
 for (const [path, expectedHash] of [
  ['./public/storagedaddy/footer-art/storagedaddy.webp', '9164eb6b49796a5263e6741ca85d51ceec01b42fac68aeb5647f90eb3d3fa8c5'],
  ['./public/storagedaddy/fonts/fleet-footer-precise-v1/geist.woff2', '19f9c92546aa300c312235e3125af1b81394d8db9a4bc4a425cd5b641d2d54e1'],
  ['./public/storagedaddy/fonts/fleet-footer-precise-v1/geistmono.woff2', '3f98383b122fe015a48536cd4a1cda855a201718923ffe74931a01597107b9b5'],
  ['./public/storagedaddy/fonts/fleet-footer-precise-v1/newsreader.woff2', '6e4f2958c3a7c4a80acde4e5a679abe7e01bc1e30b92be3c7a8b696ef401d101'],
 ]) {
  const bytes = await readFile(new URL(path, import.meta.url));
  assert.equal(createHash('sha256').update(bytes).digest('hex'), expectedHash, path);
 }
});
test('legacy landing and download links redirect to the corrected domain without counting', async () => {
 for (const [path,target] of [['/storagedaddy','/'],['/storagedaddy/','/'],['/storagedaddy/download','/download'],['/storagedaddy/assets/StorageDaddy.png','/assets/StorageDaddy.png']]) {
  const e=env(); const response=await worker.fetch(new Request('https://significanthobbies.com'+path),e);
  assert.equal(response.status,308); assert.equal(response.headers.get('location'),'https://storage.daddyrad.com'+target);
  assert.equal(e.requested.length,0); assert.equal(e.events.length,0);
 }
});
test('retired subdomain redirects every path to storage.daddyrad.com', async () => {
 for (const path of ['/', '/download', '/updates/appcast.xml', '/index.md?x=1']) {
  const e=env(); const response=await worker.fetch(new Request('https://storagedaddy.significanthobbies.com'+path),e);
  assert.equal(response.status,308); assert.equal(response.headers.get('location'),'https://storage.daddyrad.com'+path);
  assert.equal(e.requested.length,0); assert.equal(e.events.length,0);
 }
});
test('unsupported methods and routes never reach assets or analytics', async () => {
 const e=env(); assert.equal((await worker.fetch(new Request('https://storage.daddyrad.com/download',{method:'POST'}),e)).status,405);
 assert.equal((await worker.fetch(new Request('https://significanthobbies.com/hub'),e)).status,404); assert.equal(e.requested.length,0); assert.equal(e.events.length,0);
});
test('analytics failure does not break a download', async () => {
 const e=env(); e.DOWNLOADS.writeDataPoint=()=>{throw Error('unavailable')}; assert.equal((await worker.fetch(new Request('https://storage.daddyrad.com/download'),e)).status,200);
});

test('updater feed is RSS with bounded caching and does not inflate download metrics', async () => {
 const e=env(); const response=await worker.fetch(new Request('https://storage.daddyrad.com/updates/appcast.xml'),e);
 assert.equal(new URL(e.requested[0]).pathname,'/storagedaddy/updates/appcast.xml');
 assert.equal(response.headers.get('content-type'),'application/rss+xml; charset=utf-8');
 assert.equal(response.headers.get('cache-control'),'public, max-age=300');
 assert.equal(e.events.length,0);
});

test('agent endpoints keep GET and HEAD types and routes without download events', async () => {
 for (const [path, target, type] of [
  ['/api/ai', '/api/ai.json', 'application/json'],
  ['/index.md', '/index.md', 'text/markdown'],
  ['/llms.txt', '/llms.txt', 'text/plain'],
  ['/robots.txt', '/robots.txt', 'text/plain'],
  ['/sitemap.xml', '/sitemap.xml', 'application/xml'],
 ]) {
  for (const method of ['GET', 'HEAD']) {
   const e=env(); const response=await worker.fetch(new Request('https://storage.daddyrad.com'+path,{method}),e);
   assert.equal(response.status,200);
   assert.equal(new URL(e.requested[0]).pathname,'/storagedaddy'+target);
   assert.equal(response.headers.get('content-type'),type+'; charset=utf-8');
   assert.equal(e.events.length,0);
  }
 }
 const e=env(404); const response=await worker.fetch(new Request('https://storage.daddyrad.com/index.md'),e);
 assert.equal(response.status,404);
 assert.notEqual(response.headers.get('content-type'),'text/markdown; charset=utf-8');
});
