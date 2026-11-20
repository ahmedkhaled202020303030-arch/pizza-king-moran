const CACHE_NAME = 'pkm-app-shell-v3';
const APP_SHELL = [
  '/',
  '/?app=delivery',
  '/manifest.webmanifest',
  '/manifest-delivery.webmanifest',
  '/icons/app-icon.svg',
  '/icons/delivery-icon.svg'
];

self.addEventListener('install', event => {
  event.waitUntil(
    caches.open(CACHE_NAME)
      .then(cache => cache.addAll(APP_SHELL))
      .then(() => self.skipWaiting())
  );
});

self.addEventListener('activate', event => {
  event.waitUntil(
    caches.keys()
      .then(keys => Promise.all(keys.filter(key => key !== CACHE_NAME).map(key => caches.delete(key))))
      .then(() => self.clients.claim())
  );
});

self.addEventListener('fetch', event => {
  const request = event.request;
  const url = new URL(request.url);
  if (request.method !== 'GET' || url.origin !== self.location.origin) return;

  if (request.mode === 'navigate') {
    event.respondWith(
      fetch(request).then(response => {
        if (response && response.ok) {
          const copy = response.clone();
          caches.open(CACHE_NAME).then(cache => {
            cache.put(request, copy);
            if (url.pathname === '/' && !url.search) {
              cache.put('/', response.clone());
            }
          });
        }
        return response;
      }).catch(() =>
        caches.match(request).then(cached => cached || caches.match('/'))
      )
    );
    return;
  }

  if (APP_SHELL.includes(url.pathname) || url.pathname === '/manifest-delivery.webmanifest' || url.pathname === '/icons/delivery-icon.svg') {
    event.respondWith(caches.match(request).then(cached => cached || fetch(request)));
  }
});
