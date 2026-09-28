import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import vm from 'node:vm';

const source = readFileSync(new URL('./public/storagedaddy/analytics.js', import.meta.url), 'utf8');

function harness({ key = 'ahk_pub_storage', userAgent = 'Mozilla/5.0', tracker } = {}) {
  const listeners = new Map();
  const appended = [];
  const setup = { dataset: { key, project: 'storagedaddy' } };
  const document = {
    currentScript: setup,
    documentElement: { dataset: {} },
    head: { appendChild(element) { appended.push(element); } },
    addEventListener(type, callback) { listeners.set(type, callback); },
    createElement() {
      return { dataset: {}, addEventListener(type, callback) { this[type] = callback; } };
    },
  };
  const context = {
    document,
    navigator: { userAgent },
    location: { href: 'https://storage.daddyrad.com/', origin: 'https://storage.daddyrad.com' },
    window: { appHealth: tracker },
    URL,
    setTimeout,
    clearTimeout,
    Promise,
  };
  vm.runInNewContext(source, context);
  return {
    context,
    listeners,
    appended,
    dispatch(type, event) { listeners.get(type)?.({ ...event, type }); },
    anchor(href) {
      return { href, closest(selector) { return selector === 'a[href]' ? this : null; } };
    },
  };
}

function tracker() {
  return { calls: [], track(name) { this.calls.push(name); }, flush() { return Promise.resolve(); } };
}

test('records exactly one left click and one middle click for download CTAs', () => {
  const t = tracker();
  const h = harness({ tracker: t });
  h.dispatch('click', { button: 0, target: h.anchor('/download') });
  h.dispatch('click', { button: 1, target: h.anchor('/download') });
  h.dispatch('auxclick', { button: 1, target: h.anchor('/download') });
  assert.deepEqual(t.calls, ['download.clicked', 'download.clicked']);
});

test('ignores non-download links and does not capture query or private values', () => {
  const t = tracker();
  const h = harness({ tracker: t });
  h.dispatch('click', { button: 0, target: h.anchor('/pricing?email=private@example.com') });
  h.dispatch('click', { button: 0, target: h.anchor('/download?email=private@example.com') });
  assert.deepEqual(t.calls, ['download.clicked']);
  assert.equal(t.calls.some((value) => value.includes('private') || value.includes('?')), false);
});

test('records the public source repository click without recording its URL', () => {
  const t = tracker();
  const h = harness({ tracker: t });
  h.dispatch('click', { button: 0, target: h.anchor('https://github.com/sarthakagrawal927/storagedaddy') });
  h.dispatch('click', { button: 0, target: h.anchor('https://github.com/sarthakagrawal927/storagedaddy/issues/new?title=private') });
  assert.deepEqual(t.calls, ['source_opened']);
});

test('does not initialize without a public key or for bots', () => {
  const missing = harness({ key: '' });
  assert.equal(missing.appended.length, 0);
  assert.equal(missing.listeners.size, 0);
  const bot = harness({ userAgent: 'Mozilla/5.0 (compatible; Googlebot/2.1)' });
  assert.equal(bot.appended.length, 0);
  assert.equal(bot.listeners.size, 0);
});

test('duplicate initialization installs one listener pair', () => {
  const h = harness();
  vm.runInNewContext(source, h.context);
  assert.deepEqual([...h.listeners.keys()], ['click', 'auxclick']);
  assert.equal(h.appended.length, 1);
});

test('unavailable or throwing trackers never interrupt navigation', () => {
  const unavailable = harness();
  assert.doesNotThrow(() => unavailable.dispatch('click', { button: 0, target: unavailable.anchor('/download') }));
  const throwing = tracker();
  throwing.track = () => { throw new Error('collector unavailable'); };
  const h = harness({ tracker: throwing });
  const event = { button: 0, target: h.anchor('/download'), defaultPrevented: false };
  assert.doesNotThrow(() => h.dispatch('click', event));
  assert.equal(event.defaultPrevented, false);
});

test('delivers queued click after the tracker script loads', () => {
  const h = harness();
  h.dispatch('click', { button: 0, target: h.anchor('/download') });
  assert.equal(h.appended.length, 1);
  const t = tracker();
  h.context.window.appHealth = t;
  h.appended[0].load();
  assert.deepEqual(t.calls, ['download.clicked']);
});
