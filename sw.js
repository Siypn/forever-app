const CACHE_NAME = 'forever-app-v9';
// Fonts live in their own cache so an app update never throws them away.
const FONT_CACHE = 'forever-fonts-v1';
const APP_SHELL = ['./', './index.html', './manifest.json', './icon-192.png', './icon-512.png',
  './icon-maskable-192.png', './icon-maskable-512.png', './apple-touch-icon.png', './privacy.html'];

self.addEventListener('install', (event) => {
  self.skipWaiting();
  event.waitUntil(caches.open(CACHE_NAME).then((cache) =>
    Promise.all(APP_SHELL.map((u) => cache.add(u).catch(() => {})))));
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.keys().then((keys) => Promise.all(
      keys.filter((k) => k !== CACHE_NAME && k !== FONT_CACHE).map((k) => caches.delete(k))))
  );
  self.clients.claim();
});

// Google Fonts: the font files never change once published, so they're served cache-first —
// after one online open, Bebas Neue / Cinzel / Outfit load instantly with zero bars at the gym.
// The small stylesheet is served from cache and refreshed in the background.
async function fontResponse(request) {
  const cache = await caches.open(FONT_CACHE);
  const cached = await cache.match(request);
  const refresh = fetch(request).then((res) => {
    if (res && (res.ok || res.type === 'opaque')) cache.put(request, res.clone());
    return res;
  });
  if (cached) {
    refresh.catch(() => {}); // stylesheet refreshes quietly in the background; offline is fine
    return cached;
  }
  try { return await refresh; } catch (e) { return new Response('', { status: 503 }); }
}

// App files: network-first with a short timeout, so every open tries to get the latest
// version and an update shows up the first time you open the app. If the network is slow
// or gone, it falls back to the cached copy after 3 seconds so the app still opens.
self.addEventListener('fetch', (event) => {
  if (event.request.method !== 'GET') return;
  const url = new URL(event.request.url);
  if (url.hostname === 'fonts.gstatic.com') { event.respondWith(fontResponse(event.request)); return; }
  if (url.hostname === 'fonts.googleapis.com') { event.respondWith(fontResponse(event.request)); return; }
  if (url.origin !== self.location.origin) return;
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

// Reminders (sent by the server only when something's still undone today).
self.addEventListener('push', (event) => {
  let d = {};
  try { d = event.data ? event.data.json() : {}; } catch (e) { d = { body: event.data ? event.data.text() : '' }; }
  event.waitUntil(self.registration.showNotification(d.title || 'FOREVER', {
    body: d.body || '',
    tag: d.tag || 'forever',
    icon: './icon-192.png',
    badge: './icon-192.png',
    data: { url: d.url || './' },
  }));
});
self.addEventListener('notificationclick', (event) => {
  event.notification.close();
  const url = new URL((event.notification.data && event.notification.data.url) || './', self.registration.scope).href;
  event.waitUntil(self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then((list) => {
    for (const c of list) { if (c.url.startsWith(self.registration.scope) && 'focus' in c) return c.focus(); }
    return self.clients.openWindow(url);
  }));
});
