const CACHE = 'bayside-v24';
const SHELL = ['./', './index.html', './manifest.json', './icons/icon-192.png', './icons/icon-512.png', './icons/boat.png',
  './icons/sunrise.png', './icons/sunset.png', './icons/ocean.png', './icons/sun-icon.png', './icons/moon-icon.png',
  'https://unpkg.com/leaflet@1.9.4/dist/leaflet.css', 'https://unpkg.com/leaflet@1.9.4/dist/leaflet.js'];
// add each item on its own so one missing/blocked asset can't fail the whole install
self.addEventListener('install', e => { e.waitUntil(caches.open(CACHE).then(c => Promise.allSettled(SHELL.map(u => c.add(u))))); self.skipWaiting(); });
self.addEventListener('activate', e => { e.waitUntil(caches.keys().then(ks => Promise.all(ks.filter(k => k !== CACHE).map(k => caches.delete(k))))); self.clients.claim(); });

const isDoc = req => req.mode === 'navigate' || req.destination === 'document' ||
  /\/(index\.html)?(\?.*)?$/.test(new URL(req.url).pathname + new URL(req.url).search);

self.addEventListener('fetch', e => {
  const u = e.request.url;
  // live data: always network
  if (/open-meteo|tidesandcurrents|weather\.gov/.test(u)) return;
  // map tiles: cache what you've seen so the last area works with weak signal
  if (/cartocdn|arcgisonline|charttools\.noaa/.test(u)) {
    e.respondWith(caches.open('bayside-tiles').then(async c => {
      const hit = await c.match(e.request); if (hit) return hit;
      const res = await fetch(e.request).catch(() => null);
      if (res && (res.ok || res.type === 'opaque')) c.put(e.request, res.clone());
      return res || new Response('', {status: 504});
    }));
    return;
  }
  // the app page itself: network-first, so a new deploy always shows up; cache is only the offline fallback
  if (isDoc(e.request)) {
    e.respondWith((async () => {
      try {
        const res = await fetch(e.request, {cache: 'no-store'});
        const c = await caches.open(CACHE); c.put('./index.html', res.clone());
        return res;
      } catch (err) {
        return (await caches.match('./index.html')) || (await caches.match('./')) || Response.error();
      }
    })());
    return;
  }
  // everything else (leaflet, icons): cache-first, refreshed by the CACHE version bump
  e.respondWith(caches.match(e.request).then(hit => hit || fetch(e.request)));
});
