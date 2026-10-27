import { readFile, writeFile } from 'node:fs/promises';
import { handleReadability, markdown, robots, manifest } from '../agent-readability.mjs';
const target = new URL('../public/storagedaddy/', import.meta.url);
await writeFile(new URL('index.md', target), markdown);
await writeFile(new URL('robots.txt', target), robots());
for (const path of ['llms.txt', 'llms-full.txt', 'ai.txt']) {
  const response = await handleReadability(new Request(`https://storage.daddyrad.com/${path}`));
  if (!response?.ok) throw new Error(`Failed ${path}`);
  await writeFile(new URL(path, target), await response.text());
}
let html = await readFile(new URL('index.html', target), 'utf8');
html = html.replace(/<meta\b[^>]*name=["']ai-summary["'][^>]*>/gi, '');
const summary = manifest.summary.replaceAll('&', '&amp;').replaceAll('"', '&quot;').replaceAll('<', '&lt;');
html = html.replace('</head>', `<meta name="ai-summary" content="${summary}"></head>`);
await writeFile(new URL('index.html', target), html);
console.log('Generated StorageDaddy public homepage mirror and discovery documents.');
