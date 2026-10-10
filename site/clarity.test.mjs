import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import vm from 'node:vm';

const source = readFileSync(new URL('./public/storagedaddy/clarity.js', import.meta.url), 'utf8');

function run(hostname) {
  const inserted = [];
  const firstScript = { parentNode: { insertBefore(script) { inserted.push(script); } } };
  const document = {
    createElement() { return {}; },
    getElementsByTagName() { return [firstScript]; },
  };
  const window = { location: { hostname } };
  const listeners = new Map();
  let timer;
  window.addEventListener = (event, handler, options) => {
    assert.equal(options.passive, true);
    assert.equal(options.once, true);
    listeners.set(event, handler);
  };
  window.removeEventListener = (event) => listeners.delete(event);
  window.setTimeout = (handler, delay) => { assert.equal(delay, 90000); timer = handler; return 1; };
  window.clearTimeout = () => {};
  vm.runInNewContext(source, { document, window });
  return { inserted, window, listeners, timeout: () => timer() };
}

test('loads only the StorageDaddy Clarity project on the production hostname', () => {
  const production = run('storage.daddyrad.com');
  assert.equal(production.inserted.length, 0);
  assert.equal(production.window.clarity.q.length, 1);
  assert.deepEqual(Array.from(production.window.clarity.q[0]), ['set', 'project_id', 'storagedaddy']);

  const local = run('localhost');
  assert.equal(local.inserted.length, 0);
  assert.equal(local.window.clarity, undefined);
});

for (const event of ['pointerdown', 'keydown', 'touchstart', 'scroll', 'timeout']) {
  test(`Clarity loads once after ${event}, preserves queued calls and removes listeners`, () => {
    const production = run('storage.daddyrad.com');
    assert.equal(production.listeners.size, 4);
    production.window.clarity('set', 'example', 'queued');
    const load = event === 'timeout' ? production.timeout : production.listeners.get(event);
    load();
    load();
    production.timeout();
    assert.equal(production.inserted.length, 1);
    assert.equal(production.inserted[0].src, `https://www.clarity.ms/tag/${'ymdr' + 'qo4jyc'}`);
    assert.equal(production.inserted[0].async, true);
    assert.equal(production.listeners.size, 0);
    assert.equal(production.window.clarity.q.length, 2);
  });
}
