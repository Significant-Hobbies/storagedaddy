import release from './release.json' with { type: 'json' };

const base = '/storagedaddy';
const canonicalOrigin = 'https://storage.daddyrad.com';
const legacyOrigin = 'storagedaddy.significanthobbies.com';
/** @param {Env} env @param {string} event */
function record(env, event) {
  try {
    env.DOWNLOADS.writeDataPoint({ indexes: ['storagedaddy'], blobs: [event, release.version], doubles: [1] });
  } catch {
    console.warn(JSON.stringify({ event: 'measurement_unavailable' }));
  }
}
/** @param {Response} response */
function secure(response) {
  const result = new Response(response.body, response);
  result.headers.set('X-Content-Type-Options', 'nosniff');
  result.headers.set('Referrer-Policy', 'strict-origin-when-cross-origin');
  // Fleet's hosted widgets use shadow-root styles and bundled data-URI logos.
  result.headers.set('Content-Security-Policy', "default-src 'none'; img-src 'self' data: https://*.clarity.ms https://c.bing.com; style-src 'self' 'unsafe-inline'; script-src 'self' https://ingest.sassmaker.com https://sassmaker.com https://*.clarity.ms https://c.bing.com; connect-src https://ingest.sassmaker.com https://sassmaker.com https://api.sassmaker.com https://*.clarity.ms https://c.bing.com; base-uri 'none'; form-action 'none'; frame-ancestors 'none'; frame-src https://health.sassmaker.com; font-src 'self'");
  return result;
}
export default {
  /** @param {Request} request @param {Env} env */
  async fetch(request, env) {
    const url = new URL(request.url);
    if (!['GET', 'HEAD'].includes(request.method)) return new Response('Method not allowed', { status: 405, headers: { Allow: 'GET, HEAD' } });
    const legacyPath = url.pathname === base || url.pathname.startsWith(base + '/');
    if (legacyPath) return Response.redirect(canonicalOrigin + (url.pathname.slice(base.length) || '/') + url.search, 308);
    if (url.hostname === legacyOrigin) return Response.redirect(canonicalOrigin + url.pathname + url.search, 308);
    if (url.hostname === 'significanthobbies.com') return new Response('Not found', { status: 404 });
    const isDownload = url.pathname === '/download' || url.pathname === release.path.slice(base.length);
    const assetURL = new URL(request.url);
    assetURL.pathname = isDownload ? release.path : base + (url.pathname === '/api/ai' ? '/api/ai.json' : url.pathname);
    assetURL.search = '';
    const response = await env.ASSETS.fetch(new Request(assetURL, request));
    const result = secure(response);
    const agentTypes = {
      '/api/ai': 'application/json; charset=utf-8',
      '/llms.txt': 'text/plain; charset=utf-8',
      '/index.md': 'text/markdown; charset=utf-8',
      '/robots.txt': 'text/plain; charset=utf-8',
      '/sitemap.xml': 'application/xml; charset=utf-8',
    };
    if (response.ok && url.pathname in agentTypes) {
      result.headers.set('Content-Type', agentTypes[/** @type {keyof typeof agentTypes} */ (url.pathname)]);
      result.headers.set('Cache-Control', 'public, max-age=300');
    }
    if (url.pathname === "/updates/appcast.xml" && response.ok) {
      result.headers.set("Content-Type", "application/rss+xml; charset=utf-8");
      result.headers.set("Cache-Control", "public, max-age=300");
    }
    if (isDownload && response.ok) {
      result.headers.set('Content-Type', 'application/x-apple-diskimage');
      result.headers.set('Content-Disposition', `attachment; filename="${release.filename}"`);
      result.headers.set('Cache-Control', 'private, no-store');
      if (request.method === 'GET' && response.status === 200 && !request.headers.has('Range')) record(env, 'download_request');
    } else if (url.pathname === '/' && request.method === 'GET' && response.status === 200) {
      record(env, 'page_view');
    }
    return result;
  }
};
