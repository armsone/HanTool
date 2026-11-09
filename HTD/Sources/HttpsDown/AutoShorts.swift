import Foundation
import WebKit
import AppKit

/// AutoShorts integration for HTT-bundled HTD.
///
/// Automatically advances to the next YouTube Short when the active visible video ends or loop-wraps.
/// Only active when HTD is nested inside HTT.app/Contents/Helpers (verifying parent identifier).
/// Default is on; persistent user toggle available via context menu on YouTube Shorts.
enum AutoShorts {
    static let storageKey = "htd.autoShorts.enabled"
    static let menuItemID = NSUserInterfaceItemIdentifier("com.hanstree.HttpsDown.autoShortsToggle")
    static let handlerName = "htdAutoShorts"
    static let expectedParentBundleID = "com.local.screentranslator"

    /// Verified check: HTD is nested inside HTT.app/Contents/Helpers and parent bundle ID matches HTT.
    static var isBundledInHTT: Bool {
        let me = Bundle.main.bundleURL.resolvingSymlinksInPath()
        let helpers = me.deletingLastPathComponent()
        let contents = helpers.deletingLastPathComponent()
        let parentApp = contents.deletingLastPathComponent()
        guard helpers.lastPathComponent == "Helpers",
              contents.lastPathComponent == "Contents" else {
            return false
        }
        guard parentApp.lastPathComponent == "HTT.app" || parentApp.pathExtension == "app" else {
            return false
        }
        guard let parentBundle = Bundle(url: parentApp),
              let parentID = parentBundle.bundleIdentifier,
              parentID == expectedParentBundleID || parentID.hasPrefix(expectedParentBundleID) else {
            return false
        }
        return true
    }

    /// User-visible persistent on/off control. Defaults to true (on) when key is missing; a stored false remains false.
    static var isEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: storageKey) == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: storageKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: storageKey)
        }
    }

    static func isYouTubeHost(_ host: String?) -> Bool {
        guard let h = host?.lowercased() else { return false }
        return h == "www.youtube.com" || h == "youtube.com" || h == "m.youtube.com"
    }

    static func isShortsURL(_ url: URL?) -> Bool {
        guard let url = url, let host = url.host else { return false }
        guard isYouTubeHost(host) else { return false }
        let path = url.path
        return path.hasPrefix("/shorts/") || path == "/shorts"
    }

    static var userScript: WKUserScript {
        WKUserScript(source: scriptSource, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page)
    }

    @MainActor
    static func install(into ucc: WKUserContentController, model: LoginBrowserModel) {
        guard isBundledInHTT else { return }
        ucc.addUserScript(userScript)
        ucc.add(AutoShortsScriptHandler(model: model), contentWorld: .page, name: handlerName)
    }

    static let scriptSource = #"""
    (function () {
      try {
        if (window.top !== window) return;
        var host = (location.hostname || "").toLowerCase();
        if (host !== "www.youtube.com" && host !== "youtube.com" && host !== "m.youtube.com") return;
        if (window.__htdAutoShortsInstalled) return;
        window.__htdAutoShortsInstalled = true;

        const YT_SHORTS_PATH_PREFIX = "/shorts/";
        const SCAN_INTERVAL_MS = 500;
        const ADVANCE_GUARD_MS = 900;
        const NEAR_END_SECONDS = 0.2;
        const LOOP_WRAP_WINDOW_SECONDS = 0.75;

        // Keep initial false until native state arrives to avoid advancing before saved false loads.
        let enabled = false;
        let scanTimer = null;
        let lastAdvanceAt = 0;
        const boundVideos = new WeakSet();
        const lastPlaybackTimes = new WeakMap();

        function isShortsUrl() {
          var h = (location.hostname || "").toLowerCase();
          if (h !== "www.youtube.com" && h !== "youtube.com" && h !== "m.youtube.com") return false;
          return (location.pathname || "").startsWith(YT_SHORTS_PATH_PREFIX);
        }

        function isUserTyping() {
          const element = document.activeElement;
          if (!element) return false;
          if (element.isContentEditable) return true;

          const tagName = (element.tagName || "").toLowerCase();
          if (["input", "textarea", "select"].includes(tagName)) return true;

          return (element.getAttribute?.("role") || "").toLowerCase() === "textbox";
        }

        function isVisible(element) {
          if (!element) return false;
          const rect = element.getBoundingClientRect?.();
          if (!rect || rect.width <= 0 || rect.height <= 0) return false;

          if (typeof getComputedStyle === "function") {
            const style = getComputedStyle(element);
            if (style.display === "none" || style.visibility === "hidden") return false;
          }
          return true;
        }

        function getActiveVideo() {
          const videos = [...document.querySelectorAll("video")].filter(isVisible);
          if (videos.length === 0) return null;

          const playingVideo = videos.find((video) => !video.paused && !video.ended);
          if (playingVideo) return playingVideo;

          return videos.reduce((largest, video) => {
            const rect = video.getBoundingClientRect();
            const largestRect = largest.getBoundingClientRect();
            return rect.width * rect.height > largestRect.width * largestRect.height
              ? video
              : largest;
          });
        }

        function findNextButton() {
          const selectors = [
            "#navigation-button-down button",
            "button[aria-label='다음 동영상']",
            "button[aria-label='Next video']"
          ];

          for (const selector of selectors) {
            const button = [...document.querySelectorAll(selector)].find(
              (candidate) => isVisible(candidate) && !candidate.disabled
            );
            if (button) return button;
          }
          return null;
        }

        function dispatchArrowDown() {
          const target = document.body || document.documentElement;
          const options = {
            key: "ArrowDown",
            code: "ArrowDown",
            keyCode: 40,
            which: 40,
            bubbles: true,
            cancelable: true
          };
          target.dispatchEvent(new KeyboardEvent("keydown", options));
          target.dispatchEvent(new KeyboardEvent("keyup", options));
        }

        function advanceToNextShort() {
          if (!enabled || !isShortsUrl() || isUserTyping()) return false;

          const now = Date.now();
          if (now - lastAdvanceAt < ADVANCE_GUARD_MS) {
            return false;
          }

          lastAdvanceAt = now;

          const nextButton = findNextButton();
          if (nextButton) {
            nextButton.click();
          } else {
            dispatchArrowDown();
          }
          return true;
        }

        function onVideoEnded(event) {
          if (!enabled || !isShortsUrl()) return;
          const activeVideo = getActiveVideo();
          if (activeVideo && event.currentTarget !== activeVideo) return;
          advanceToNextShort();
        }

        function onVideoTimeUpdate(event) {
          if (!enabled || !isShortsUrl()) return;
          const video = event.currentTarget;
          const activeVideo = getActiveVideo();
          if (activeVideo && video !== activeVideo) return;

          const duration = Number(video.duration);
          const currentTime = Number(video.currentTime);
          if (!Number.isFinite(duration) || duration <= 0 || !Number.isFinite(currentTime)) return;

          const previousTime = lastPlaybackTimes.get(video);
          lastPlaybackTimes.set(video, currentTime);

          const isNearEnd = duration - currentTime <= NEAR_END_SECONDS;
          const loopWrapped =
            Number.isFinite(previousTime) &&
            previousTime >= duration - LOOP_WRAP_WINDOW_SECONDS &&
            currentTime <= Math.min(LOOP_WRAP_WINDOW_SECONDS, duration * 0.15);

          if (isNearEnd || loopWrapped) advanceToNextShort();
        }

        function bindAvailableVideos() {
          if (!enabled || !isShortsUrl()) return;

          for (const video of document.querySelectorAll("video")) {
            if (boundVideos.has(video)) continue;
            boundVideos.add(video);
            video.addEventListener("ended", onVideoEnded);
            video.addEventListener("timeupdate", onVideoTimeUpdate);
          }
        }

        window.__htdAutoShorts = {
          setEnabled: function (val) {
            enabled = !!val;
            if (enabled) {
              bindAvailableVideos();
            }
          },
          isEnabled: function () {
            return enabled;
          }
        };

        function install() {
          try {
            if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.htdAutoShorts) {
              window.webkit.messageHandlers.htdAutoShorts.postMessage({ type: "getState" });
            }
          } catch (e) {}

          window.addEventListener("popstate", bindAvailableVideos);
          window.addEventListener("yt-navigate-finish", bindAvailableVideos);
          scanTimer = window.setInterval(bindAvailableVideos, SCAN_INTERVAL_MS);
        }

        function uninstall() {
          if (scanTimer !== null) {
            window.clearInterval(scanTimer);
            scanTimer = null;
          }
          window.removeEventListener("popstate", bindAvailableVideos);
          window.removeEventListener("yt-navigate-finish", bindAvailableVideos);
        }

        install();
        window.addEventListener("beforeunload", uninstall);
      } catch (e) {}
    })();
    """#
}

@MainActor
final class AutoShortsScriptHandler: NSObject, WKScriptMessageHandler {
    weak var model: LoginBrowserModel?

    init(model: LoginBrowserModel) {
        self.model = model
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        model?.receiveAutoShortsMessage(message)
    }
}
