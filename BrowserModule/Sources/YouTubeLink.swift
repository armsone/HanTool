import WebKit

/// Resolves which YouTube video a click/drag meant: the nearest clicked link, else the nearest card around the
/// pointer (shadow roots and composed paths included). Only youtube.com / *.youtube.com / youtu.be video addresses
/// (watch?v=, /shorts/ID, /live/ID, youtu.be/ID) count; thumbnails (i.ytimg.com) are never a video, and a card that
/// holds several different videos resolves to nothing instead of an unrelated one. Pure page reading, no clicks.
enum YouTubeLink {
    static let dragWorld = WKContentWorld.world(name: "HttpsDownYouTubeDrag")

    /// JS function definitions (`htdYTPoint(x, y)` for a context-menu position, `htdYTNode(node)` for a drag target).
    /// Both return a canonical video address or null.
    static let functions = #"""
    var htdYTHost = /(?:^|\.)youtube\.com$|^youtu\.be$/i;
    var htdYTCard = /^(?:yt-lockup-view-model|ytd-thumbnail|ytd-video-preview|ytd-[a-z-]*(?:renderer|lockup)[a-z-]*|ytm-[a-z-]*(?:renderer|lockup)[a-z-]*)$/;
    function htdYTVideo(raw, base) {
      try {
        var u = new URL(raw, base), h = u.hostname.toLowerCase(), id = null, kind = 'watch', m;
        if (u.protocol !== 'https:' && u.protocol !== 'http:') return null;
        if (h === 'youtu.be') { m = u.pathname.match(/^\/([A-Za-z0-9_-]{11})\/?$/); id = m && m[1]; }
        else if (htdYTHost.test(h)) {
          if (u.pathname === '/watch') id = u.searchParams.get('v');
          else { m = u.pathname.match(/^\/(shorts|live)\/([A-Za-z0-9_-]{11})\/?$/); if (m) { kind = m[1]; id = m[2]; } }
        }
        if (!id || !/^[A-Za-z0-9_-]{11}$/.test(id)) return null;
        return kind === 'watch' ? 'https://www.youtube.com/watch?v=' + id : 'https://www.youtube.com/' + kind + '/' + id;
      } catch (e) { return null; }
    }
    function htdYTNode(start) {
      var node = start;
      for (var depth = 0; node && depth < 40; depth++) {
        if (node.nodeType === 1) {
          if (node.tagName === 'A' && node.getAttribute('href') !== null) {
            var own = htdYTVideo(node.href || node.getAttribute('href'), node.baseURI);
            if (own) return own;
            var nonVideo = false; try { var pu = new URL(node.href || node.getAttribute('href'), node.baseURI); nonVideo = pu.protocol === 'https:' || pu.protocol === 'http:'; } catch (e) {}
            if (nonVideo) return null;
          }
          if (htdYTCard.test(node.tagName.toLowerCase())) {
            var seen = {}, count = 0, found = null;
            var roots = [node]; if (node.shadowRoot) roots.push(node.shadowRoot);
            for (var r = 0; r < roots.length; r++) {
              var links = roots[r].querySelectorAll('a[href]');
              for (var i = 0; i < links.length && i < 60; i++) {
                var v = htdYTVideo(links[i].href || links[i].getAttribute('href'), links[i].baseURI);
                if (v && !seen[v]) { seen[v] = 1; count++; found = v; }
              }
            }
            if (count === 1) return found;
            if (count > 1) return null;
          }
        }
        node = node.assignedSlot || node.parentNode || (node.host || null);
      }
      return null;
    }
    function htdYTPoint(x, y) {
      var el = document.elementFromPoint(x, y);
      for (var i = 0; i < 8 && el && el.shadowRoot; i++) {
        var inner = el.shadowRoot.elementFromPoint(x, y);
        if (!inner || inner === el) break;
        el = inner;
      }
      return htdYTNode(el);
    }
    """#

    /// Top-frame user script: gives a drag that starts on a video card/thumbnail a URL payload (the existing download
    /// drop target reads it). The page's own drag behaviour is untouched; nothing is queued by the drag itself.
    static var dragScript: WKUserScript {
        let source = "(function () { try { if (window !== window.top || !/(?:^|\\.)youtube\\.com$/i.test(location.hostname)) return;\n"
            + functions
            + #"""
            window.addEventListener('dragstart', function (e) {
              try {
                if (!e.isTrusted || !e.dataTransfer) return;
                var path = e.composedPath ? e.composedPath() : [e.target];
                var url = htdYTNode(path[0]);
                if (!url) return;
                e.dataTransfer.setData('text/uri-list', url);
                e.dataTransfer.setData('text/plain', url);
                // The page's own later dragstart handlers must not cancel the drag (no preventDefault here).
                e.stopImmediatePropagation();
              } catch (err) {}
            }, true);
            var marked = [];
            function restore() {
              while (marked.length) {
                var m = marked.pop();
                if (m.previous === null) m.node.removeAttribute('draggable'); else m.node.setAttribute('draggable', m.previous);
              }
            }
            function mark(n) {
              if (!n || n.nodeType !== 1) return;
              for (var i = 0; i < marked.length; i++) if (marked[i].node === n) return;
              marked.push({ node: n, previous: n.getAttribute('draggable') });
              n.setAttribute('draggable', 'true');
            }
            window.addEventListener('pointerdown', function (e) {
              try {
                restore();
                if (e.button !== 0 || !e.isTrusted) return;
                var path = e.composedPath ? e.composedPath() : [e.target], target = null;
                for (var i = 0; i < path.length && i < 40; i++) {
                  var n = path[i];
                  if (!n || n.nodeType !== 1) continue;
                  if (/^(?:input|textarea|select|button|option|label|form)$/i.test(n.tagName) || n.isContentEditable) return;
                  if (n.tagName === 'A' && n.getAttribute('href') !== null) {
                    if (!htdYTVideo(n.href || n.getAttribute('href'), n.baseURI)) return;
                    target = n; break;
                  }
                  if (!target && htdYTCard.test(n.tagName.toLowerCase())) target = n;
                }
                if (!target || !htdYTNode(path[0])) return;
                // Native image drag starts from the actual pointer target (often the thumbnail image), so mark it too.
                mark(path[0]);
                mark(target);
              } catch (err) {}
            }, true);
            window.addEventListener('pointerup', restore, true);
            window.addEventListener('dragend', restore, true);
            } catch (e) {} })();
            """#
        return WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: dragWorld)
    }
}
