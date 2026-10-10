import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';
import test from 'node:test';
import vm from 'node:vm';

const root = new URL('./public/storagedaddy/', import.meta.url);
const html = readFileSync(new URL('index.html', root), 'utf8');
const source = 'https://github.com/sarthakagrawal927/storagedaddy';
const content = JSON.parse(readFileSync(new URL('./landing/src/content/storagedaddy.json', import.meta.url), 'utf8'));
const compat = JSON.parse(readFileSync(new URL('./landing/src/content/head-compat.json', import.meta.url), 'utf8'));
const tags = (name) => [...html.matchAll(new RegExp(`<${name}\\b[^>]*>`, 'gi'))].map(([tag]) => tag);
const attr = (tag, name) => tag.match(new RegExp(`\\b${name}="([^"]*)"`))?.[1];

test('home preserves discovery metadata and the StudioFooter identity', () => {
  const canonical = tags('link').filter((tag) => attr(tag, 'rel') === 'canonical');
  assert.equal(canonical.length, 1);
  assert.equal(attr(canonical[0], 'href'), 'https://storage.daddyrad.com/');
  assert.match(html, /<footer\b[^>]*data-fleet-footer="studio"[^>]*data-catalog-id="storagedaddy"/);
  assert.match(html, /data-subscribe[^>]*data-catalog="storagedaddy"/);
  assert.match(html, /<title>Free Mac Disk Space Analyzer for Developers \| storagedaddy<\/title>/);
  assert.ok(content.page.description.length >= 70 && content.page.description.length <= 160);
  for (const [name, expected] of [
    ['description', content.page.description],
    ['robots', 'index, follow, max-image-preview:large'],
    ['theme-color', '#050706'],
    ['twitter:description', compat.twitterDescription],
  ]) {
    const matching = tags('meta').filter((tag) => attr(tag, 'name') === name);
    assert.equal(matching.length, 1, name);
    assert.equal(attr(matching[0], 'content'), expected, name);
  }
  const ld = [...html.matchAll(/<script\b[^>]*type="application\/ld\+json"[^>]*>([\s\S]*?)<\/script>/g)].flatMap(([, data]) => JSON.parse(data));
  assert.deepEqual(ld, content.page.jsonLd);
  for (const [type, href] of [['text/markdown', '/index.md'], ['application/json', '/api/ai']]) {
    assert.ok(tags('link').some((tag) => attr(tag, 'rel') === 'alternate' && attr(tag, 'type') === type && attr(tag, 'href') === href));
  }
});

test('home loads analytics and all executable scripts externally under the existing CSP', () => {
  assert.match(html, /<script defer src="\/clarity\.js"><\/script>/);
  const analytics = tags('script').filter((tag) => attr(tag, 'src') === '/analytics.js');
  assert.equal(analytics.length, 1);
  assert.match(analytics[0], /\bdefer\b/);
  assert.equal(attr(analytics[0], 'data-key'), 'ahk_pub_ab3311cd5d9186c1910936f52a28e4c523575518aa3991a9ffded4952e55cb8f');
  assert.equal(attr(analytics[0], 'data-project'), 'app-3262e567-f7cc-48bc-a528-4e3845185b41');
  for (const [, attrs, body] of html.matchAll(/<script\b([^>]*)>([\s\S]*?)<\/script>/gi)) {
    if (attr(attrs, 'type') === 'application/ld+json') continue;
    assert.equal(body.trim(), '', 'Executable inline script');
    const src = attr(attrs, 'src');
    assert.ok(src?.startsWith('/') && !src.startsWith('//'), `Non-local script: ${src}`);
  }
  assert.doesNotMatch(html, /\bon\w+\s*=/i, 'Inline event handlers');
  assert.doesNotMatch(html, /project-strip\.js|ai-chat-footer\.js|href="style\.css"|<iframe\b/);
  assert.doesNotMatch(html, /\bformaction=/i, 'Ask AI must navigate without submitting a form');
});

test('home navigation, download and source links resolve to the intended targets', () => {
  const ids = new Set([...html.matchAll(/\bid="([^"]+)"/g)].map(([, id]) => id));
  let downloads = 0;
  for (const tag of tags('a')) {
    const href = attr(tag, 'href');
    assert.notEqual(href, '#');
    if (href?.startsWith('#')) assert.ok(ids.has(decodeURIComponent(href.slice(1))), href);
    if (href && new URL(href.replaceAll('&amp;', '&'), 'https://storage.daddyrad.com/').pathname === '/download') {
      assert.equal(href, '/download');
      downloads++;
    }
  }
  assert.ok(downloads >= 4);
  assert.match(html, new RegExp(`<a[^>]*href="${source}"[^>]*>View source</a>`));
  assert.doesNotMatch(html, /github\.com\/Significant-Hobbies\/storagedaddy/);
  for (const { text, href } of compat.faqLinks) {
    assert.ok(html.includes(`href="${href}"`), text);
  }
});

test('FAQ keeps the live privacy disclosure, cleanup limits and installation facts', () => {
  for (const phrase of [
    'Does storagedaddy upload my files?', 'What does it need Full Disk Access for?',
    'Is cleanup automatic?', 'What does an AI archive include?', 'How do I install it?',
    'Why is Mac System Data large, and can storagedaddy show it?', 'Is storagedaddy free and open source?',
    'App Health and Microsoft Clarity', 'Anonymous browser identifiers recognize repeat visits;',
    'website analytics do not receive your disk contents or app activity.',
    'Download counts do not prove installation or use.', 'Intel Macs are not supported.',
    'Third-party libraries and provider artwork retain their own terms;',
  ]) assert.ok(html.includes(phrase), phrase);
  assert.ok(html.includes('href="https://support.apple.com/102624"'));
});

test('all home and Astro assets, including CSS fonts and script chunks, are packaged locally', () => {
  const queue = [{ text: html, base: '/' }];
  const visited = new Set();
  while (queue.length) {
    const { text, base } = queue.pop();
    const paths = [...text.matchAll(/(\/(?:_astro|home)\/[a-zA-Z0-9_.-]+)/g)].map(([, path]) => path);
    if (base === '/_astro/') {
      for (const [, file] of text.matchAll(/["'`](\.\/[a-zA-Z0-9_.-]+\.js)["'`]/g)) paths.push(base + file.slice(2));
    }
    for (const path of paths) {
      assert.ok(existsSync(new URL(`.${path}`, root)), `Missing asset: ${path}`);
      if (visited.has(path)) continue;
      visited.add(path);
      if (/\.(?:css|js)$/.test(path)) queue.push({ text: readFileSync(new URL(`.${path}`, root), 'utf8'), base: '/_astro/' });
    }
  }
  assert.ok(visited.has('/home/icon-44.webp'));
  assert.ok(visited.has('/home/storage-explorer-1405.webp'));
  assert.ok(visited.has('/home/ai-context-700.webp'));
  assert.ok(visited.has('/home/storagedaddy-scene-1536.webp'));
});

test('Ask AI opens only the clicked assistant with the edited question and no form submission', () => {
  const handlers = {};
  const opened = [];
  const script = readFileSync(new URL('./landing/src/scripts/ask-ai.js', import.meta.url), 'utf8');
  vm.runInNewContext(script, {
    document: { addEventListener: (name, handler) => { handlers[name] = handler; } },
    window: { open: (...args) => opened.push(args) }, URL,
  });
  assert.equal(opened.length, 0);
  handlers.click({ target: { closest: () => null } });
  assert.equal(opened.length, 0);
  let prevented = false;
  handlers.click({
    target: { closest: () => ({ dataset: { assistantUrl: 'https://chatgpt.com/' }, closest: () => ({ querySelector: () => ({ value: 'Is cleanup automatic? & private' }) }) }) },
    preventDefault: () => { prevented = true; },
  });
  assert.ok(prevented);
  assert.equal(opened.length, 1);
  assert.equal(new URL(opened[0][0]).searchParams.get('q'), 'Is cleanup automatic? & private');
  assert.equal(new URL(opened[0][0]).origin, 'https://chatgpt.com');
  assert.equal(opened[0][2], 'noopener,noreferrer');
  const buttons = tags('button').filter((tag) => attr(tag, 'data-assistant-url'));
  assert.equal(buttons.length, 4);
  for (const button of buttons) assert.equal(attr(button, 'type'), 'button');
});

test('home uses responsive modern images and lazy loads below-fold details', () => {
  const images = tags('img');
  assert.equal(images.length, 5);
  for (const image of images) {
    assert.ok(attr(image, 'src').endsWith('.webp'));
    assert.ok(attr(image, 'srcset'));
    assert.ok(attr(image, 'sizes'));
    assert.ok(Number(attr(image, 'width')) > 0);
    assert.ok(Number(attr(image, 'height')) > 0);
    for (const candidate of attr(image, 'srcset').split(', ')) {
      assert.ok(existsSync(new URL(`.${candidate.split(' ')[0]}`, root)));
    }
  }
  const hero = images.find((image) => attr(image, 'src').includes('storage-explorer-'));
  assert.equal(attr(hero, 'loading'), 'eager');
  assert.equal(attr(hero, 'fetchPriority'), 'high');
  for (const name of ['storage-detail', 'ai-context']) {
    assert.equal(attr(images.find((image) => attr(image, 'src').includes(name)), 'loading'), 'lazy');
  }
  assert.doesNotMatch(html, /background-image:url\(\/home\//);
  const fonts = tags('link').filter((tag) => attr(tag, 'as') === 'font');
  assert.equal(fonts.length, 1);
  assert.match(attr(fonts[0], 'href'), /figtree-latin-normal.*\.woff2$/);
});
