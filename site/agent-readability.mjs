import compat from './landing/src/content/head-compat.json' with { type: 'json' };
import content from './landing/src/content/storagedaddy.json' with { type: 'json' };
import { templateMarkdown } from './scripts/template-markdown.mjs';
import { absoluteMarkdownLinks } from './agent-surfaces/format.mjs';
import { createAgentSurfaceManifest } from './agent-surfaces/manifest.mjs';
import { createAgentSurfaceHandler } from './agent-surfaces/handler.mjs';
export { advertiseMarkdown } from './agent-surfaces/adapters/static-assets.mjs';

export const origin = 'https://storage.daddyrad.com';
let mainMarkdown = templateMarkdown(content);
for (const { text, href } of compat.faqLinks) {
  if (!mainMarkdown.includes(text)) throw new Error(`Missing FAQ link text: ${text}`);
  mainMarkdown = mainMarkdown.replace(text, `[${text}](${href})`);
}
export const markdown = `# ${content.page.title}\n\n> ${content.page.description}\n\nCanonical HTML: ${origin}/\n\n${absoluteMarkdownLinks(mainMarkdown, origin + '/')}`;
const excluded = ['/api', '/admin', '/auth', '/dashboard'];
export const manifest = createAgentSurfaceManifest({
  name: 'StorageDaddy', url: origin, summary: content.page.description,
  contact: 'https://github.com/sarthakagrawal927/storagedaddy/issues',
  trainingAllowed: true, excludedPaths: excluded,
  notes: ['## Download and source', '', `[Download](${origin}/download)`, '[Source and feedback](https://github.com/sarthakagrawal927/storagedaddy)'],
  sitemap: origin + '/sitemap.xml', pages: { '/': markdown },
});
const handle = createAgentSurfaceHandler({ manifest });
export async function handleReadability(request) {
  const path = new URL(request.url).pathname;
  // Keep the established release/download and API discovery contracts intact.
  if (path === '/api/ai') return null;
  if (path === '/robots.txt' && ['GET', 'HEAD'].includes(request.method)) return new Response(request.method === 'HEAD' ? null : robots(), { headers: { 'Content-Type': 'text/plain; charset=utf-8', 'Cache-Control': 'public, max-age=300' } });
  return handle(request);
}
export function robots() {
  const bots = ['*', 'GPTBot', 'ClaudeBot', 'Google-Extended', 'Applebot-Extended', 'CCBot', 'Bytespider', 'OAI-SearchBot', 'ChatGPT-User', 'Claude-SearchBot', 'Claude-User', 'PerplexityBot', 'Perplexity-User'];
  return bots.map((bot) => `User-agent: ${bot}\nAllow: /\n${excluded.map((path) => `Disallow: ${path}`).join('\n')}\nAllow: /api/ai$\nAllow: /api/md$\nAllow: /api/md/`).join('\n\n') + `\n\nSitemap: ${origin}/sitemap.xml\n# Keep in sync with ai.txt and llms.txt.\n`;
}
