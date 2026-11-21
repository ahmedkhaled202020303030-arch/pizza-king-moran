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

self.addEventListener('push', event => {
  let payload = {};
  try { payload = event.data ? event.data.json() : {}; } catch { payload = { title: 'Pizza King & Morin', body: event.data?.text() || 'لديك تحديث جديد في طلبات الدليفري.' }; }
  event.waitUntil(self.registration.showNotification(payload.title || 'Pizza King & Morin', {
    body: payload.body || 'لديك تحديث جديد في طلبات الدليفري.',
    icon: '/icons/app-icon-192.png',
    badge: '/icons/app-icon-192.png',
    tag: payload.tag || 'pkm-delivery-update',
    renotify: true,
    data: { url: payload.url || '/?view=delivery-orders' },
    dir: 'rtl',
    lang: 'ar'
  }));
});
self.addEventListener('notificationclick', event => {
  event.notification.close();
  const target = new URL(event.notification.data?.url || '/?view=delivery-orders', self.location.origin).href;
  event.waitUntil(clients.matchAll({ type: 'window', includeUncontrolled: true }).then(list => {
    for (const client of list) {
      if (client.url.startsWith(self.location.origin) && 'focus' in client) {
        client.navigate(target);
        return client.focus();
      }
    }
    return clients.openWindow(target);
  }));
});
