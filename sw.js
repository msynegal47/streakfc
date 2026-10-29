const CACHE = 'streakfc-v57';
const OFFLINE_URLS = ['/', '/index.html', '/manifest.json', '/icon-192.png', '/icon-512.png', '/logo.png', '/apple-touch-icon.png'];

self.addEventListener('install', e => {
  e.waitUntil(caches.open(CACHE).then(c => c.addAll(OFFLINE_URLS)));
  self.skipWaiting();
});

self.addEventListener('activate', e => {
  e.waitUntil(caches.keys().then(keys =>
    Promise.all(keys.filter(k => k !== CACHE).map(k => caches.delete(k)))
  ));
  self.clients.claim();
});

self.addEventListener('fetch', e => {
  const url = new URL(e.request.url);
  // Pass through Supabase calls
  if (url.hostname.includes('supabase.co')) return;
  e.respondWith(
    fetch(e.request).catch(() => caches.match(e.request).then(r => r || caches.match('/index.html')))
  );
});

// Streak reminders (web push)
self.addEventListener('push', e => {
  let d = {}; try { d = e.data ? e.data.json() : {}; } catch (x) { d = {title: 'StreakFC', body: e.data ? e.data.text() : ''}; }
  e.waitUntil(self.registration.showNotification(d.title || 'StreakFC', {body: d.body || '', icon: '/icon-192.png', badge: '/icon-192.png', tag: d.tag || 'streak', data: {url: d.url || '/'}}));
});
self.addEventListener('notificationclick', e => {
  e.notification.close();
  const url = (e.notification.data && e.notification.data.url) || '/';
  e.waitUntil(self.clients.matchAll({type: 'window', includeUncontrolled: true}).then(cs => { for (const c of cs) { if ('focus' in c) return c.focus(); } return self.clients.openWindow(url); }));
});
