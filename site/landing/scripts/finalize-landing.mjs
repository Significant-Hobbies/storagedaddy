import { createHash } from 'node:crypto';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import compat from '../src/content/head-compat.json' with { type: 'json' };
import { optimizeLanding } from '../../scripts/optimize-landing.mjs';

const escapeHtml = (value) => value.replaceAll('&', '&amp;').replaceAll('"', '&quot;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll("'", '&#x27;');

// v0.1.13 emits inline footer JS, shares OG/Twitter text, and has text-only FAQ
// answers. Adapt the static output locally without mutating installed packages.
export async function finalizeLanding(dir) {
  const index = new URL('index.html', dir);
  let html = await readFile(index, 'utf8');
  // StudioFooter's Ask AI GET form is blocked by form-action 'none'. The local
  // click handler navigates instead, preserving the editable question.
  html = html.replace(/<button\b[^>]*\bformaction="[^"]+"[^>]*>/gi, (tag) =>
    tag.replace('type="submit"', 'type="button"').replace(/formaction=/i, 'data-assistant-url='));
  const scripts = [];
  html = html.replace(/<script\b([^>]*)>([\s\S]*?)<\/script>/gi, (tag, attrs, body) => {
    if (/\bsrc\s*=/.test(attrs) || /\btype="application\/ld\+json"/.test(attrs)) return tag;
    if (!body.trim()) return tag;
    const hash = createHash('sha256').update(body).digest('hex').slice(0, 16);
    const file = `landing-${hash}.js`;
    scripts.push({ file, body });
    return `<script${attrs} src="/_astro/${file}"${/\btype="module"/.test(attrs) ? '' : ' defer'}></script>`;
  });
  await mkdir(new URL('_astro/', dir), { recursive: true });
  for (const { file, body } of scripts) await writeFile(new URL(`_astro/${file}`, dir), body);
  const twitter = /<meta name="twitter:description" content="[^"]*"\s*\/?\s*>/;
  if (!twitter.test(html)) throw new Error('Base no longer emits the expected Twitter description');
  html = html.replace(twitter, `<meta name="twitter:description" content="${escapeHtml(compat.twitterDescription)}">`);
  for (const { text, href } of compat.faqLinks) {
    const escaped = escapeHtml(text);
    if (!html.includes(escaped)) throw new Error(`Missing FAQ link text: ${text}`);
    html = html.replace(escaped, `<a href="${escapeHtml(href)}">${escaped}</a>`);
  }
  await writeFile(index, html);
  await optimizeLanding(dir);
}
