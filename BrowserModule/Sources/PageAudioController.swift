import Foundation
import WebKit
import Combine
import SwiftUI
import AppKit

// MARK: - Surface Kinds

enum PageAudioSurfaceKind {
    case ordinaryTab(LoginBrowserModel)
    case sawTab(LoginBrowserModel, projectID: UUID)
    case aiServicePanel(ThirdPartyAIPanelHost)
    case aiLoginWindow(window: NSWindow, serviceName: String)
    case aiProbe(serviceName: String)
    case aiPlanner(service: String)
    case sawHanaAdapter
    case hanaPanel
    case popup(window: NSWindow, title: String)
}

enum TabAudioState: Equatable {
    case silent
    case playingAudible
    case playingMuted
}

// MARK: - Sounding Surface Entry (for UI Menu)

struct PageAudioMenuEntry: Identifiable {
    let id = UUID()
    let displayLabel: String
    let isAudible: Bool
    let isPlaying: Bool
    var canJump: Bool = true
    let jumpAction: (AppModel) -> Void

    func jump(appModel: AppModel) {
        jumpAction(appModel)
    }
}

// MARK: - Registration Holder

@MainActor
final class PageAudioRegistration {
    weak var webView: WKWebView?
    private let kindResolver: () -> PageAudioSurfaceKind
    var kind: PageAudioSurfaceKind { kindResolver() }
    var isAudible: Bool = false
    var isPlaying: Bool = false
    var hasWebAudio: Bool = false
    var lastReportedDocID: String = ""
    var frameStates: [String: (WKFrameInfo, Date, Bool, Bool)] = [:]
    var observedFrames: [WKFrameInfo] { frameStates.values.map { $0.0 } }
    var navigationObservation: NSKeyValueObservation?

    init(webView: WKWebView, kind: PageAudioSurfaceKind) {
        self.webView = webView
        switch kind {
        case .ordinaryTab(let model), .sawTab(let model, _):
            self.kindResolver = { [weak model] in
                guard let model = model else { return .aiProbe(serviceName: "") }
                if let pid = model.sawProjectID {
                    return .sawTab(model, projectID: pid)
                } else {
                    return .ordinaryTab(model)
                }
            }
        case .aiServicePanel(let host):
            self.kindResolver = { [weak host] in
                if let host = host { return .aiServicePanel(host) }
                return .aiProbe(serviceName: "")
            }
        case .aiLoginWindow(let window, let serviceName):
            self.kindResolver = { [weak window] in
                if let window = window { return .aiLoginWindow(window: window, serviceName: serviceName) }
                return .aiProbe(serviceName: "")
            }
        case .popup(let window, let title):
            self.kindResolver = { [weak window] in
                if let window = window { return .popup(window: window, title: title) }
                return .aiProbe(serviceName: "")
            }
        default:
            self.kindResolver = { kind }
        }
    }

    func refreshFrames() {
        let now = Date()
        for (id, (frame, date, _, _)) in frameStates where now.timeIntervalSince(date) > 8.0 {
            frameStates[id] = (frame, date, false, false)
        }
        isPlaying = frameStates.values.contains { $0.2 }
        isAudible = frameStates.values.contains { $0.3 }
    }
}

// MARK: - PageAudioController

@MainActor
final class PageAudioController: NSObject, ObservableObject, WKScriptMessageHandler {
    static let shared = PageAudioController()

    @Published private(set) var isGlobalMuted: Bool = false
    @Published private(set) var activeAudioEntries: [PageAudioMenuEntry] = []

    private var registrations: [PageAudioRegistration] = []
    private let configuredUCCs = NSHashTable<WKUserContentController>.weakObjects()

    static let handlerName = "htdPageAudio"

    private static let scriptSource = #"""
    (function() {
      if (window.__htdAudioControllerInstalled) return;
      window.__htdAudioControllerInstalled = true;

      let globalMuted = false;
      const docId = Math.random().toString(36).slice(2) + Date.now().toString(36);
      const trackedElements = new Set();
      let hasWebAudioContext = false;
      const audioContexts = new Set();

      function postAudioState() {
        let anyAudible = false;
        let anyPlaying = false;

        for (const el of Array.from(trackedElements)) {
          if (!el.isConnected) {
            trackedElements.delete(el);
            continue;
          }
          const isPlaying = !el.paused && !el.ended && el.readyState >= 2;
          const userMuted = (typeof el.__htdUserMuted !== 'undefined') ? el.__htdUserMuted : el.muted;
          const audible = isPlaying && !origMutedDesc.get.call(el) && el.volume > 0;
          if (isPlaying) anyPlaying = true;
          if (audible) anyAudible = true;
        }

        

        try {
          if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.htdPageAudio) {
            window.webkit.messageHandlers.htdPageAudio.postMessage({
              type: 'audioState',
              docId: docId,
              isAudible: anyAudible,
              isPlaying: anyPlaying,
              hasWebAudio: hasWebAudioContext
            });
          }
        } catch (e) {}
      }

      let debounceTimer = null;
      function scheduleNotify() {
        if (debounceTimer) return;
        debounceTimer = setTimeout(() => {
          debounceTimer = null;
          postAudioState();
        }, 150);
      }

      const proto = HTMLMediaElement.prototype;
      const origMutedDesc = Object.getOwnPropertyDescriptor(proto, 'muted');

      function trackMedia(el) {
        if (!el || trackedElements.has(el)) return;
        trackedElements.add(el);
        if (typeof el.__htdUserMuted === 'undefined') {
          el.__htdUserMuted = origMutedDesc ? origMutedDesc.get.call(el) : el.muted;
        }
        if (globalMuted && origMutedDesc) {
          if (!origMutedDesc.get.call(el)) { origMutedDesc.set.call(el, true); }
        }
      }

      if (origMutedDesc && origMutedDesc.configurable) {
        Object.defineProperty(proto, 'muted', {
          get: function() {
            trackMedia(this);
            return origMutedDesc.get.call(this);
          },
          set: function(val) {
            trackMedia(this);
            this.__htdUserMuted = Boolean(val);
            if (globalMuted) {
              if (!origMutedDesc.get.call(this)) { origMutedDesc.set.call(this, true); }
            } else {
              origMutedDesc.set.call(this, Boolean(val));
            }
            scheduleNotify();
          },
          configurable: true,
          enumerable: origMutedDesc.enumerable
        });
      }

      const mediaEvents = ['play', 'playing', 'pause', 'ended', 'volumechange', 'loadedmetadata', 'canplay'];
      for (const ev of mediaEvents) {
        window.addEventListener(ev, function(e) {
          if (e.target instanceof HTMLMediaElement) {
            trackMedia(e.target);
            if (globalMuted && origMutedDesc) {
              if (!origMutedDesc.get.call(e.target)) { origMutedDesc.set.call(e.target, true); }
            }
            scheduleNotify();
          }
        }, true);
      }

      try {
        const observer = new MutationObserver(mutations => {
          for (const m of mutations) {
            for (const node of m.addedNodes) {
              if (node instanceof HTMLMediaElement) {
                trackMedia(node);
              } else if (node.querySelectorAll) {
                const list = node.querySelectorAll('audio, video');
                for (const el of list) trackMedia(el);
              }
            }
          }
        });
        observer.observe(document, { childList: true, subtree: true });
      } catch (e) {}

      window.__htdAudioApplyGlobalMute = function(mute) {
        globalMuted = Boolean(mute);
        for (const el of Array.from(trackedElements)) {
          if (!el.isConnected) {
            trackedElements.delete(el);
            continue;
          }
          if (origMutedDesc) {
            if (globalMuted) {
              if (!origMutedDesc.get.call(el)) { origMutedDesc.set.call(el, true); }
            } else {
              const restoreVal = (typeof el.__htdUserMuted !== 'undefined') ? el.__htdUserMuted : false;
              origMutedDesc.set.call(el, restoreVal);
            }
          }
        }

        try {
          const all = document.querySelectorAll('audio, video');
          for (const el of all) {
            trackMedia(el);
            if (origMutedDesc) {
              if (globalMuted) {
                if (!origMutedDesc.get.call(el)) { origMutedDesc.set.call(el, true); }
              } else {
                const restoreVal = (typeof el.__htdUserMuted !== 'undefined') ? el.__htdUserMuted : false;
                origMutedDesc.set.call(el, restoreVal);
              }
            }
          }
        } catch (e) {}

        

        scheduleNotify();
      };

      document.querySelectorAll('audio, video').forEach(trackMedia);
      setInterval(postAudioState, 1000);
      try {
        if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.htdPageAudio) {
          window.webkit.messageHandlers.htdPageAudio.postMessage({
            type: 'frameInit',
            docId: docId
          });
        }
      } catch (e) {}
    })();
    """#

    private var frameTimer: Timer?

    private override init() {
        super.init()
        frameTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.cleanDeadRegistrations()
                self?.updateActiveAudioEntries()
            }
        }
    }

    // MARK: - Script Installation

    func prepareConfiguration(_ configuration: WKWebViewConfiguration) {
        let ucc = configuration.userContentController
        guard !configuredUCCs.contains(ucc) else { return }
        configuredUCCs.add(ucc)

        let script = WKUserScript(
            source: Self.scriptSource,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false,
            in: .page
        )
        ucc.addUserScript(script)
        ucc.add(self, contentWorld: .page, name: Self.handlerName)
    }

    // MARK: - View Registration

    func register(webView: WKWebView, kind: PageAudioSurfaceKind) {
        cleanDeadRegistrations()
        registrations.removeAll { $0.webView === webView }
        let reg = PageAudioRegistration(webView: webView, kind: kind)
        reg.navigationObservation = webView.observe(\WKWebView.url, options: [.new]) { [weak self, weak reg] _, _ in
            Task { @MainActor [weak self, weak reg] in
                reg?.frameStates.removeAll()
                reg?.refreshFrames()
                self?.updateActiveAudioEntries()
            }
        }
        registrations.append(reg)

        if isGlobalMuted {
            webView.evaluateJavaScript("window.__htdAudioApplyGlobalMute?.(true)", in: nil, in: .page) { _ in }
        }
    }

    func register(webView: WKWebView, model: LoginBrowserModel) {
        if let sawWorkspace = model.sawWorkspace, let pid = model.sawProjectID {
            register(webView: webView, kind: .sawTab(model, projectID: pid))
        } else {
            register(webView: webView, kind: .ordinaryTab(model))
        }
    }

    // MARK: - Script Message Handler

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == Self.handlerName,
              let webView = message.webView,
              let body = message.body as? [String: Any],
              let type = body["type"] as? String,
              let docId = body["docId"] as? String,
              !docId.isEmpty, docId.count <= 128 else {
            return
        }

        cleanDeadRegistrations()
        guard let reg = registrations.first(where: { $0.webView === webView }) else { return }
        guard type == "frameInit" || type == "audioState" else { return }
        guard reg.frameStates[docId] != nil || reg.frameStates.count < 128 || (message.frameInfo.isMainFrame && type == "frameInit") else { return }

        if type == "frameInit" {
            if message.frameInfo.isMainFrame {
                reg.frameStates.removeAll()
            }
            reg.frameStates[docId] = (message.frameInfo, Date(), false, false)
            if reg.frameStates.count > 128 {
                reg.refreshFrames()
            }
            webView.callAsyncJavaScript("window.__htdAudioApplyGlobalMute?.(isMuted)",
                                       arguments: ["isMuted": isGlobalMuted],
                                       in: message.frameInfo,
                                       in: .page) { _ in }
            reg.refreshFrames()
            updateActiveAudioEntries()
            return
        }

        if type == "audioState" {
            let isAudible = (body["isAudible"] as? Bool) ?? false
            let isPlaying = (body["isPlaying"] as? Bool) ?? false
            reg.frameStates[docId] = (message.frameInfo, Date(), isPlaying, isAudible)
            reg.lastReportedDocID = docId
            reg.refreshFrames()
            updateActiveAudioEntries()
        }
    }

    // MARK: - State & Controls

    func audioState(for webView: WKWebView?) -> TabAudioState {
        guard let wv = webView else { return .silent }
        guard let reg = registrations.first(where: { $0.webView === wv }) else { return .silent }
        if reg.isPlaying || reg.isAudible {
            if isGlobalMuted || !reg.isAudible {
                return .playingMuted
            } else {
                return .playingAudible
            }
        }
        return .silent
    }

    func toggleGlobalMute() {
        isGlobalMuted.toggle()
        applyGlobalMuteToAllViews(isGlobalMuted)
        updateActiveAudioEntries()
    }

    func setGlobalMute(_ mute: Bool) {
        guard isGlobalMuted != mute else { return }
        isGlobalMuted = mute
        applyGlobalMuteToAllViews(mute)
        updateActiveAudioEntries()
    }

    private func applyGlobalMuteToAllViews(_ mute: Bool) {
        cleanDeadRegistrations()
        for reg in registrations {
            guard let wv = reg.webView else { continue }
            wv.evaluateJavaScript("window.__htdAudioApplyGlobalMute?.(\(mute))", in: nil, in: .page) { _ in }
            for frame in reg.observedFrames {
                wv.callAsyncJavaScript("window.__htdAudioApplyGlobalMute?.(isMuted)",
                                       arguments: ["isMuted": mute],
                                       in: frame,
                                       in: .page) { _ in }
            }
        }
    }

    private func cleanDeadRegistrations() {
        registrations.removeAll { reg in
            guard let wv = reg.webView else { return true }
            if case .ordinaryTab(let m) = reg.kind, m.webView !== wv { return true }
            if case .sawTab(let m, _) = reg.kind, m.webView !== wv { return true }
            return false
        }
        for reg in registrations { reg.refreshFrames() }
    }

    private func updateActiveAudioEntries() {
        cleanDeadRegistrations()
        var entries: [PageAudioMenuEntry] = []

        for reg in registrations {
            guard let wv = reg.webView, reg.isAudible || reg.isPlaying else { continue }

            let effectiveAudible = reg.isAudible && !isGlobalMuted
            switch reg.kind {
            case .aiProbe:
                continue
            case .ordinaryTab(let tab):
                let title = tab.tabTitle
                let tabID = tab.tabID
                let entry = PageAudioMenuEntry(
                    displayLabel: "[브라우저] \(title)",
                    isAudible: effectiveAudible,
                    isPlaying: reg.isPlaying
                ) { [weak tab] appModel in
                    guard tab != nil, appModel.tabs.contains(where: { $0.tabID == tabID }) else { return }
                    appModel.selectTab(tabID)
                    appModel.selectedTab = .browser
                }
                entries.append(entry)

            case .sawTab(let tab, let projectID):
                let projectTitle = tab.sawWorkspace?.store.projects.first(where: { $0.id == projectID })?.title ?? "플래너"
                let title = tab.tabTitle
                let tabID = tab.tabID
                let entry = PageAudioMenuEntry(
                    displayLabel: "[플래너: \(projectTitle)] \(title)",
                    isAudible: effectiveAudible,
                    isPlaying: reg.isPlaying
                ) { [weak tab] appModel in
                    guard tab != nil else { return }
                    if let session = appModel.sawWorkspace.existingSession(for: projectID), session.tabs.contains(where: { $0.tabID == tabID }) {
                        appModel.sawWorkspace.selectProject(projectID)
                        session.selectTab(id: tabID)
                        appModel.selectedTab = .saw
                    }
                }
                entries.append(entry)

            case .aiServicePanel(let host):
                let name = host.currentService?.name ?? "AI"
                let entry = PageAudioMenuEntry(
                    displayLabel: "[AI 사이드패널] \(name)",
                    isAudible: effectiveAudible,
                    isPlaying: reg.isPlaying
                ) { appModel in
                    appModel.selectedTab = .browser
                    appModel.setAIPanelOpen(true)
                }
                entries.append(entry)

            case .aiLoginWindow(let window, let serviceName):
                let entry = PageAudioMenuEntry(
                    displayLabel: "[AI 로그인] \(serviceName)",
                    isAudible: effectiveAudible,
                    isPlaying: reg.isPlaying
                ) { [weak window] _ in
                    window?.makeKeyAndOrderFront(nil)
                }
                entries.append(entry)

            case .aiPlanner(let service):
                let entry = PageAudioMenuEntry(
                    displayLabel: "[AI 플래너] \(service)",
                    isAudible: effectiveAudible,
                    isPlaying: reg.isPlaying,
                    canJump: false
                ) { _ in }
                entries.append(entry)

            case .sawHanaAdapter:
                let entry = PageAudioMenuEntry(
                    displayLabel: "[AI 플래너] 하나",
                    isAudible: effectiveAudible,
                    isPlaying: reg.isPlaying,
                    canJump: false
                ) { _ in }
                entries.append(entry)

            case .hanaPanel:
                let entry = PageAudioMenuEntry(
                    displayLabel: "[AI 어시스턴트] 하나",
                    isAudible: effectiveAudible,
                    isPlaying: reg.isPlaying
                ) { _ in
                    HanaPanelHost.shared.isPanelOpen = true
                }
                entries.append(entry)

            case .popup(let window, let title):
                let entry = PageAudioMenuEntry(
                    displayLabel: "[팝업 창] \(title)",
                    isAudible: effectiveAudible,
                    isPlaying: reg.isPlaying
                ) { [weak window] _ in
                    window?.makeKeyAndOrderFront(nil)
                }
                entries.append(entry)
            }
        }

        self.activeAudioEntries = entries
    }
}
