// HttpsDown media discovery. Injected into every frame of the app's own browser in an ISOLATED content world:
// page scripts cannot see or call the `hdMedia` handler. Reports only candidate video addresses (hints), never
// reads form fields, passwords or cookies, and never starts a download by itself.
(function () {
  'use strict';
  if (window.__hdMediaInstalled) { return; }
  window.__hdMediaInstalled = true;
  var handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.hdMedia;
  if (!handler) { return; }

  var MAX_ITEMS = 40;
  var MAX_URL = 4096;
  var FILE_RE = /\.(mp4|m4v|mov|webm|mkv)$/i;
  var HLS_RE = /\.m3u8$/i;
  var DASH_RE = /\.mpd$/i;
  var IMAGE_RE = /\.(gif|png|jpe?g|webp|avif|svg|bmp|ico|heic)$/i;
  var AD_RE = /(doubleclick|googlesyndication|googleadservices|adservice|imasdk|adsystem|adnxs|taboola|outbrain|\/ads?\/|\/vast\/|[?&]ad_?type=)/i;

  var seen = {};
  var items = [];
  var dirty = false;
  var ticks = 0;
  var lastHref = location.href;
  var resSeen = 0;   // resource-timing entries already processed (the buffer is append-only)

  function label(el) {
    var t = '';
    if (el && el.getAttribute) { t = el.getAttribute('title') || el.getAttribute('aria-label') || ''; }
    if (!t) { t = document.title || ''; }
    return String(t).replace(/[\u0000-\u001f\u007f]/g, ' ').trim().slice(0, 200);
  }

  function add(raw, source, title, mime) {
    if (items.length >= MAX_ITEMS || typeof raw !== 'string' || !raw || raw.length > MAX_URL) { return; }
    var u;
    try { u = new URL(raw, document.baseURI); } catch (e) { return; }
    if (u.protocol === 'blob:') {
      // MediaSource playback: the blob address cannot be fetched outside this page. Reported as unsupported only.
      if (source !== 'element' || seen['blob:']) { return; }
      seen['blob:'] = 1;
      items.push({ url: '', kind: 'blob', source: source, title: title });
      dirty = true;
      return;
    }
    if (u.protocol !== 'http:' && u.protocol !== 'https:') { return; }
    u.hash = '';
    var path = u.pathname;
    if (IMAGE_RE.test(path) || AD_RE.test(u.href)) { return; }
    var m = String(mime || '').toLowerCase();
    var kind = null;
    if (HLS_RE.test(path) || m.indexOf('mpegurl') >= 0) { kind = 'hls'; }
    else if (DASH_RE.test(path) || m.indexOf('dash+xml') >= 0) { kind = 'dash'; }
    else if (FILE_RE.test(path) || m.indexOf('video/') === 0) { kind = 'file'; }
    else if (source === 'element') { kind = 'element'; }
    if (!kind || seen[u.href]) { return; }
    seen[u.href] = 1;
    items.push({ url: u.href, kind: kind, source: source, title: typeof title === 'function' ? title() : title });
    dirty = true;
  }

  function scanElements() {
    var vids = document.getElementsByTagName('video');
    for (var i = 0; i < vids.length && i < 50; i++) {
      var v = vids[i];
      var t = label(v);
      add(v.currentSrc, 'element', t, '');
      add(v.src, 'element', t, '');
      var srcs = v.getElementsByTagName('source');
      for (var j = 0; j < srcs.length && j < 20; j++) { add(srcs[j].src, 'element', t, srcs[j].type); }
    }
  }

  function addEntries(list) {
    // The page title is read at most once per batch, and only when an entry actually becomes a candidate.
    var cached = null;
    var lazyTitle = function () { if (cached === null) { cached = label(null); } return cached; };
    for (var i = 0; i < list.length && i < 500; i++) {
      var e = list[i];
      if (e && typeof e.name === 'string') { add(e.name, 'resource', lazyTitle, ''); }
    }
  }

  function scanResources() {
    try {
      var list = performance.getEntriesByType('resource');
      // Only entries added since the last scan (local buffer read, no network); first 500 as before.
      var from = list.length >= resSeen ? resSeen : 0;
      resSeen = Math.min(list.length, 500);
      if (from < 500) { addEntries(list.slice(from, 500)); }
    } catch (e) {}
  }

  function send(force) {
    if (!dirty && !force) { return; }
    dirty = false;
    try {
      handler.postMessage({ v: 1, type: 'media', top: window === window.top, items: items.slice(0, MAX_ITEMS) });
    } catch (e) {}
  }

  function scan(force) {
    // Same-document (SPA) page change: the old page's addresses no longer apply.
    if (window === window.top && location.href !== lastHref) {
      lastHref = location.href;
      reset();
    }
    scanElements();
    scanResources();
    send(force);
  }

  function reset() {
    seen = {};
    items = [];
    resSeen = 0;
    dirty = true;
  }

  // Short, finite rescan burst after player readiness events / manual refresh: local DOM + resource-buffer reads only.
  // Players often attach their source a moment after the first event; this shortens the wait without long polling.
  var BURST_MS = [250, 600, 1200, 2000, 3500, 5500, 8000, 12000];
  var burstTimers = [];
  var burstAt = 0;
  function stopBurst() {
    for (var i = 0; i < burstTimers.length; i++) { clearTimeout(burstTimers[i]); }
    burstTimers = [];
  }
  function burst(force) {
    var now = Date.now();
    if (!force && now - burstAt < 1000) { return; }
    burstAt = now;
    stopBurst();
    BURST_MS.forEach(function (ms) {
      burstTimers.push(setTimeout(function () { scan(false); }, ms));
    });
  }

  // Called by the app's "다시 찾기" (same isolated world only).
  window.__hdScan = function () { reset(); scan(true); burst(true); };

  var pending = null;
  function schedule() {
    if (pending) { return; }
    pending = setTimeout(function () { pending = null; scan(false); }, 300);
  }

  try {
    new MutationObserver(schedule).observe(document, { childList: true, subtree: true, attributes: true,
                                                       attributeFilter: ['src'] });
  } catch (e) {}
  try {
    new PerformanceObserver(function (list) { addEntries(list.getEntries()); send(false); })
      .observe({ type: 'resource', buffered: true });
  } catch (e) {}
  ['play', 'playing', 'loadedmetadata', 'loadstart', 'canplay'].forEach(function (name) {
    document.addEventListener(name, function () { schedule(); burst(false); }, true);
  });
  window.addEventListener('pageshow', function () { reset(); scan(true); burst(true); });
  window.addEventListener('pagehide', stopBurst);
  ['popstate', 'hashchange'].forEach(function (name) {
    window.addEventListener(name, function () { scan(false); burst(true); });
  });
  document.addEventListener('visibilitychange', function () {
    if (document.hidden) { stopBurst(); } else { burst(false); }
  });
  document.addEventListener('DOMContentLoaded', function () { scan(false); burst(false); });

  // Reduced safety heartbeat for players that attach sources without any event we see (e.g. inside shadow DOM):
  // every 4 s, at most 30 times (2 min), skipped while hidden. Events and bursts above carry the normal updates.
  var timer = setInterval(function () {
    ticks += 1;
    if (!document.hidden) { scan(false); }
    if (ticks >= 30) { clearInterval(timer); }
  }, 4000);

  scan(false);
  burst(false);
})();
