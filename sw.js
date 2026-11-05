// Keeps the page working offline: in a power cut the router, and with it the internet, is off too
const CACHE = "battery-v1";
const FILES = ["./", "index.html", "manifest.webmanifest", "icon-192.png", "icon-512.png"];

self.addEventListener("install", (e) => {
  e.waitUntil(caches.open(CACHE).then((c) => c.addAll(FILES)));
  self.skipWaiting();
});

self.addEventListener("activate", (e) => {
  e.waitUntil(caches.keys().then((keys) => Promise.all(keys.filter((k) => k !== CACHE).map((k) => caches.delete(k)))));
  self.clients.claim();
});

// Network first, so updates arrive while online; the saved copy when the network fails or hangs
// (Wi-Fi on a UPS with the provider down)
self.addEventListener("fetch", (e) => {
  if (e.request.method !== "GET" || new URL(e.request.url).origin !== location.origin) return;
  const cached = () => caches.match(e.request, { ignoreSearch: true }).then((r) => r || caches.match("index.html"));
  const network = fetch(e.request).then((r) => {
    if (r.ok) {
      const copy = r.clone();
      caches.open(CACHE).then((c) => c.put(e.request, copy));
    }
    return r;
  });
  const timeout = new Promise((_, reject) => setTimeout(reject, 4000));
  e.respondWith(Promise.race([network, timeout]).catch(() => cached().then((r) => r || network)));
});
