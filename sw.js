// Offline support: the page loads from the network when online (so updates show), and from cache with no signal.
const CACHE = "vtaper-v14";
const CORE = ["./", "index.html", "manifest.webmanifest", "icon-180.png", "icon-192.png", "icon-512.png"];

self.addEventListener("install", e => {
  e.waitUntil(caches.open(CACHE).then(c => c.addAll(CORE)).then(() => self.skipWaiting()));
});

self.addEventListener("activate", e => {
  e.waitUntil(caches.keys()
    .then(keys => Promise.all(keys.filter(k => k !== CACHE).map(k => caches.delete(k))))
    .then(() => self.clients.claim()));
});

self.addEventListener("fetch", e => {
  const req = e.request;
  if (req.method !== "GET") return;
  const url = new URL(req.url);

  // The page itself: network first, cached copy when offline
  if (req.mode === "navigate") {
    e.respondWith(fetch(req)
      .then(res => { const copy = res.clone(); caches.open(CACHE).then(c => c.put("index.html", copy)); return res; })
      .catch(() => caches.match("index.html")));
    return;
  }

  // Fonts and other files: cached copy first, refreshed in the background
  if (url.origin === location.origin || url.host.endsWith("fonts.googleapis.com") || url.host.endsWith("fonts.gstatic.com") || url.host==="cdn.jsdelivr.net") {
    e.respondWith(caches.open(CACHE).then(async c => {
      const hit = await c.match(req);
      const net = fetch(req).then(res => { if (res && (res.ok || res.type === "opaque")) c.put(req, res.clone()); return res; }).catch(() => hit);
      return hit || net;
    }));
  }
});

// Push notifications: show them, and open the right screen when tapped.
self.addEventListener("push", e => {
  let d = {};
  try { d = e.data ? e.data.json() : {}; } catch (_) { d = { title: "V-Taper", body: e.data ? e.data.text() : "" }; }
  e.waitUntil(self.registration.showNotification(d.title || "V-Taper", {
    body: d.body || "", tag: d.tag || undefined, renotify: !!d.tag, icon: "icon-192.png", badge: "icon-192.png", data: { url: d.url || "" }
  }));
});
self.addEventListener("notificationclick", e => {
  e.notification.close();
  const url = (e.notification.data && e.notification.data.url) || "";
  e.waitUntil(self.clients.matchAll({ type: "window", includeUncontrolled: true }).then(list => {
    for (const c of list) { if ("focus" in c) { c.postMessage({ type: "open", url }); return c.focus(); } }
    return self.clients.openWindow("./" + url);
  }));
});
