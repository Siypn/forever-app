const CACHE_NAME = 'forever-app-v2';
const APP_SHELL = ['./', './index.html', './manifest.json', './icon-192.png', './icon-512.png', './apple-touch-icon.png'];

self.addEventListener('install', (event) => {
  self.skipWaiting();
  event.waitUntil(caches.open(CACHE_NAME).then((cache) => cache.addAll(APP_SHELL).catch(() => {})));
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.keys().then((keys) => Promise.all(keys.filter((k) => k !== CACHE_NAME).map((k) => caches.delete(k))))
  );
  self.clients.claim();
});

// Network-first with a short timeout: every open tries to fetch the latest version, so an
// update shows up the first time you open the app (the old stale-while-revalidate version
// always showed the previous build once). If the network is slow or gone — zero bars at the
// gym — it falls back to the cached copy after 3 seconds so the app still opens.
self.addEventListener('fetch', (event) => {
  if (event.request.method !== 'GET') return;
  if (new URL(event.request.url).origin !== self.location.origin) return;
  event.respondWith((async () => {
    const cache = await caches.open(CACHE_NAME);
    const network = fetch(event.request, { cache: 'no-cache' }).then((response) => {
      if (response && response.status === 200) cache.put(event.request, response.clone());
      return response;
    });
    const timeout = new Promise((resolve) => setTimeout(resolve, 3000, null));
    try {
      const fresh = await Promise.race([network, timeout]);
      if (fresh) return fresh;
    } catch (e) { /* offline — fall through to cache */ }
    const cached = await cache.match(event.request);
    if (cached) return cached;
    try { return await network; } catch (e) {
      return new Response('Offline and not cached yet.', { status: 503 });
    }
  })());
});
