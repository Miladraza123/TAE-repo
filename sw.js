// Service worker (§3/§26): network-first for HTML (a new deploy is picked
// up immediately, never served stale), cache-first-with-background-refresh
// for static assets. NEVER intercepts Supabase API calls or any non-GET
// request — those always go straight to the network or the in-app offline
// queue, never the service-worker cache.
'use strict';

const CACHE_NAME = 'tae-shell-v1';
const PRECACHE_URLS = [
  './index.html', './masters.html', './billing.html', './daily-ledger.html', './reports.html',
  './manifest.json', './icons/icon-192.png', './icons/icon-512.png'
];

self.addEventListener('install', (event) => {
  event.waitUntil(
    caches.open(CACHE_NAME).then((cache) => cache.addAll(PRECACHE_URLS)).catch(() => {})
  );
  self.skipWaiting();
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.keys().then((keys) =>
      Promise.all(keys.filter((k) => k !== CACHE_NAME).map((k) => caches.delete(k)))
    )
  );
  self.clients.claim();
});

function isSupabaseApiRequest(url) {
  return url.pathname.startsWith('/rest/v1/') || url.pathname.startsWith('/auth/v1/') || url.pathname.startsWith('/rpc/')
    || url.hostname.endsWith('.supabase.co');
}

self.addEventListener('fetch', (event) => {
  const req = event.request;
  if (req.method !== 'GET') return; // never intercept writes — those go to the network or the app's own offline queue

  const url = new URL(req.url);
  if (isSupabaseApiRequest(url)) return; // never cache API calls

  if (req.mode === 'navigate' || req.headers.get('accept')?.includes('text/html')) {
    event.respondWith(
      fetch(req, { cache: 'no-store' })
        .then((res) => {
          caches.open(CACHE_NAME).then((cache) => cache.put(req, res.clone()));
          return res;
        })
        .catch(() => caches.match(req))
    );
    return;
  }

  // Static assets: cache-first, with a silent background refresh for next time.
  event.respondWith(
    caches.match(req).then((cached) => {
      const network = fetch(req).then((res) => {
        caches.open(CACHE_NAME).then((cache) => cache.put(req, res.clone()));
        return res;
      }).catch(() => cached);
      return cached || network;
    })
  );
});
