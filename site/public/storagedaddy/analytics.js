(() => {
  const setup = document.currentScript;
  const key = setup?.dataset.key;
  // A public key is required. Never initialize with a server/private ingestion key.
  if (!key?.startsWith('ahk_pub_') || document.documentElement.dataset.storageDaddyAnalytics) return;
  if (/bot\b|crawler|spider|slurp|facebookexternalhit|ChatGPT-User|HeadlessChrome|curl\/|wget\//i.test(navigator.userAgent)) return;
  document.documentElement.dataset.storageDaddyAnalytics = 'true';
  const queuedEvents = [];

  function deliver() {
    const tracker = window.appHealth;
    if (!tracker) return;
    try {
      while (queuedEvents.length > 0) {
        tracker.track(queuedEvents.shift());
      }
      // Navigation and downloads never wait for analytics.
      Promise.resolve(tracker.flush()).catch(() => {});
    } catch { /* Measurement must never interrupt downloading the app. */ }
  }
  function downloadClick(event) {
    if (event.defaultPrevented || (event.type === 'click' ? event.button !== 0 : event.button !== 1)) return;
    const anchor = event.target?.closest?.('a[href]');
    if (!anchor) return;
    let url;
    try { url = new URL(anchor.href, location.href); } catch { return; }
    const eventName = url.origin === location.origin && url.pathname === '/download'
      ? 'download.clicked'
      : url.origin === 'https://github.com' && url.pathname === '/sarthakagrawal927/storagedaddy'
        ? 'source_opened'
        : null;
    if (!eventName || queuedEvents.length >= 20) return;
    queuedEvents.push(eventName);
    deliver();
  }
  document.addEventListener('click', downloadClick, { passive: true });
  document.addEventListener('auxclick', downloadClick, { passive: true });
  if (window.appHealth) return;
  const tracker = document.createElement('script');
  tracker.src = 'https://ingest.sassmaker.com/tracker.js';
  tracker.async = true;
  tracker.dataset.key = key;
  tracker.dataset.project = setup.dataset.project || 'storagedaddy';
  tracker.dataset.identity = 'persistent';
  tracker.dataset.endpoint = 'https://ingest.sassmaker.com/v1/browser';
  tracker.addEventListener('load', deliver, { once: true });
  document.head.appendChild(tracker);
})();
