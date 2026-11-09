import Foundation
import AppKit
import WebKit

@MainActor
public final class BrowserScreenshotManager: ObservableObject {
    public static let shared = BrowserScreenshotManager()

    @Published public private(set) var isCapturing: Bool = false
    @Published public private(set) var captureStatus: String? = nil

    private var currentCancelToken: UUID?
    /// Token of a full-page loop that has not finished its page cleanup (hidden fixed/sticky elements, scroll position).
    /// While set no new capture may start, even after the capture itself was cancelled; released when the cleanup script
    /// answered or after `cleanupTimeoutNanos` (WebView closed / navigating / script error), so it can never stay locked.
    private var cleanupLock: UUID?
    private static let cleanupTimeoutNanos: UInt64 = 3_000_000_000
    private weak var activeModel: LoginBrowserModel?
    private var selectionOverlay: ScreenshotSelectionView?
    private var escapeMonitor: Any?
    /// The full-page preview window is owned here (never by the view hierarchy); `isCapturing` stays set while it is open.
    private var previewController: ScreenshotPreviewController?
    private var previewIdentity: PageIdentity?
    private var previewTimer: Timer?
    @Published public private(set) var isPreviewing: Bool = false

    /// Runaway guard for endless pages only (CSS px); ordinary long pages are limited by the pixel budget below.
    private static let maxTotalHeight: CGFloat = 200_000.0
    /// Upper bound of the one stitched bitmap (4 bytes per pixel ≈ 360 MB); slices are drawn into it one at a time
    /// and released, so nothing else of this size is alive.
    private static let maxTotalPixels = 90_000_000
    /// Output pixels per CSS pixel, tried in order (those above the screen's own scale are skipped): the first one whose
    /// whole page fits the pixel budget is used, so a tall page is stored at a lower density instead of being cut off.
    private static let pixelScaleSteps: [CGFloat] = [2, 1.5, 1.25, 1, 0.75, 0.5]
    /// Waits (all cancellable, polled every `pollNanos`, each bounded): the page must show no pending/undecoded images near
    /// the viewport and keep its height for `quiet` before a position counts as settled.
    private static let pollNanos: UInt64 = 100_000_000
    private static let preloadQuietNanos: UInt64 = 250_000_000
    private static let preloadStepMaxNanos: UInt64 = 2_500_000_000
    private static let preloadBottomQuietNanos: UInt64 = 700_000_000
    private static let preloadBottomMaxNanos: UInt64 = 5_000_000_000
    private static let preloadBudgetNanos: UInt64 = 150_000_000_000
    private static let maxPreloadSteps = 400
    /// All slices of one capture (restarts included); an endless page ends here with what was captured so far.
    private static let sliceBudgetNanos: UInt64 = 300_000_000_000
    private static let sliceQuietNanos: UInt64 = 250_000_000
    private static let sliceMaxNanos: UInt64 = 3_000_000_000
    private static let lastSliceQuietNanos: UInt64 = 700_000_000
    private static let lastSliceMaxNanos: UInt64 = 5_000_000_000
    /// Page grew/shrank while slices were taken: the capture starts over this many times at most.
    private static let maxCaptureRestarts = 4
    /// The probe runs in its own isolated world: nothing is added to the page's own JavaScript namespace.
    private static let shotWorld = WKContentWorld.world(name: "HttpsDownShot")
    private static let minSelectionSide: CGFloat = 8

    private init() {}

    public func cancelCapture() {
        currentCancelToken = nil
        activeModel = nil
        tearDownSelection()
        closePreview()
        // A loop that is still cleaning the page keeps the capture busy until it is done.
        isCapturing = cleanupLock != nil
        captureStatus = nil
    }

    /// Releases the preview window and the captured image it holds. Never calls back into the manager, so it is safe from
    /// every path (cancel, tab change, navigation, save done).
    private func closePreview() {
        previewTimer?.invalidate()
        previewTimer = nil
        previewIdentity = nil
        isPreviewing = false
        guard let controller = previewController else { return }
        previewController = nil
        controller.teardown()
        // The controller may be inside one of its own button actions right now: keep it alive for one more run loop turn.
        DispatchQueue.main.async { withExtendedLifetime(controller) {} }
    }

    /// The tab lost its place (another tab became active): a capture of that tab ends without saving anything.
    func cancelCapture(for model: LoginBrowserModel) {
        if activeModel === model { cancelCapture() }
    }

    private func tearDownSelection() {
        if let monitor = escapeMonitor { NSEvent.removeMonitor(monitor) }
        escapeMonitor = nil
        selectionOverlay?.onSelect = nil
        selectionOverlay?.onCancel = nil
        selectionOverlay?.removeFromSuperview()
        selectionOverlay = nil
    }

    /// Everything that identifies "the page the user is looking at"; any difference later discards the capture.
    fileprivate struct PageIdentity {
        let webView: WKWebView
        let sessionToken: Int
        let generation: Int
        let url: URL?

        @MainActor init(webView: WKWebView, model: LoginBrowserModel) {
            self.webView = webView
            self.sessionToken = model.sessionToken
            self.generation = model.generation
            self.url = model.currentURL
        }

        @MainActor func matches(_ model: LoginBrowserModel?) -> Bool {
            guard let model = model else { return false }
            return model.webView === webView && model.sessionToken == sessionToken
                && model.generation == generation && model.currentURL == url && webView.window != nil
        }
    }

    // MARK: - Selected Area Capture

    /// Shows a drag-to-select overlay laid exactly over the web view (a subview of it, so it can never be offset from
    /// the page); only the dragged rectangle is captured. Escape (or the 취소 button, tab change, navigation) cancels.
    func captureVisibleArea(appModel: AppModel, model: LoginBrowserModel) {
        guard !isCapturing, cleanupLock == nil, !BrowserAdHideManager.shared.isEditing else { return }
        guard let wv = model.webView, !model.isShowingHome, model.currentURL != nil, wv.window != nil else {
            model.lastError = "캡처할 수 있는 웹 페이지가 열려 있지 않습니다."
            return
        }
        let bounds = wv.bounds
        guard bounds.width >= Self.minSelectionSide, bounds.height >= Self.minSelectionSide,
              bounds.width.isFinite, bounds.height.isFinite else {
            model.lastError = "웹 페이지 화면 크기를 확인할 수 없습니다."
            return
        }

        let token = UUID()
        let identity = PageIdentity(webView: wv, model: model)
        currentCancelToken = token
        activeModel = model
        isCapturing = true
        captureStatus = "캡처할 영역을 마우스로 드래그해 선택하세요. (Esc: 취소)"

        let overlay = ScreenshotSelectionView(frame: bounds)
        overlay.autoresizingMask = [.width, .height]
        overlay.onCancel = { [weak self] in
            guard let self = self, self.currentCancelToken == token else { return }
            self.cancelCapture()
            model.notice = "영역 캡처를 취소했습니다."
        }
        overlay.onSelect = { [weak self, weak model, weak appModel] rect in
            guard let self = self, self.currentCancelToken == token, let model = model, let appModel = appModel else { return }
            self.finishSelection(rect, overlay: overlay, identity: identity, token: token, appModel: appModel, model: model)
        }
        wv.addSubview(overlay)
        selectionOverlay = overlay
        wv.window?.makeFirstResponder(overlay)

        // Escape also works when the overlay is not first responder (focus moved by a click elsewhere).
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak overlay] event in
            guard event.keyCode == 53 else { return event }
            MainActor.assumeIsolated { overlay?.onCancel?() }
            return nil
        }
    }

    private func finishSelection(_ overlayRect: NSRect, overlay: ScreenshotSelectionView, identity: PageIdentity,
                                 token: UUID, appModel: AppModel, model: LoginBrowserModel) {
        let wv = identity.webView
        guard identity.matches(model) else {
            cancelCapture()
            model.lastError = "페이지가 바뀌어 영역 캡처를 취소했습니다."
            return
        }
        // Overlay coordinates -> web view coordinates (the overlay is its subview, so this also handles flipping).
        let rect = overlay.convert(overlayRect, to: wv).intersection(wv.bounds).integral
        guard rect.width >= Self.minSelectionSide, rect.height >= Self.minSelectionSide,
              rect.origin.x.isFinite, rect.origin.y.isFinite else {
            cancelCapture()
            model.lastError = "선택한 영역이 너무 작아 캡처하지 않았습니다."
            return
        }

        // Selection finished: the overlay goes away before the snapshot is taken.
        tearDownSelection()
        captureStatus = "선택한 영역을 캡처하는 중입니다..."

        let configuration = WKSnapshotConfiguration()
        configuration.rect = rect
        configuration.afterScreenUpdates = true

        wv.takeSnapshot(with: configuration) { [weak self, weak model, weak appModel] image, error in
            DispatchQueue.main.async {
                guard let self = self, self.currentCancelToken == token else { return }
                self.currentCancelToken = nil
                self.activeModel = nil
                self.isCapturing = false
                self.captureStatus = nil

                guard let model = model, let appModel = appModel else { return }
                guard identity.matches(model) else {
                    model.lastError = "캡처 중 탭이나 페이지가 바뀌어 저장하지 않았습니다."
                    return
                }
                if let error = error {
                    model.lastError = "화면 캡처에 실패했습니다: \(error.localizedDescription)"
                    return
                }
                guard let image = image,
                      let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
                      let pngData = Self.pngData(from: cg) else {
                    model.lastError = "화면 캡처 이미지를 PNG로 변환하지 못했습니다."
                    return
                }

                let title = model.pageTitle.isEmpty ? (identity.url?.host ?? "웹화면") : model.pageTitle
                let filename = "\(Self.sanitizeFilename(title))_영역캡처_\(Self.timestampString()).png"
                do {
                    let targetURL = try Self.writeUnique(pngData, folder: appModel.destinationFolder, preferredFilename: filename)
                    model.notice = "선택 영역 캡처를 저장했습니다: \(targetURL.lastPathComponent)"
                    model.lastError = nil
                } catch {
                    model.lastError = "화면 캡처 파일을 저장하지 못했습니다: \(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: - Full Page Capture

    func captureFullPage(appModel: AppModel, model: LoginBrowserModel) {
        guard !isCapturing, cleanupLock == nil, !BrowserAdHideManager.shared.isEditing else { return }
        guard let wv = model.webView, !model.isShowingHome, model.currentURL != nil, wv.window != nil else {
            model.lastError = "캡처할 수 있는 웹 페이지가 열려 있지 않습니다."
            return
        }

        let token = UUID()
        let identity = PageIdentity(webView: wv, model: model)
        self.currentCancelToken = token
        self.activeModel = model
        isCapturing = true
        captureStatus = "전체 페이지 정보를 확인하는 중..."

        let metricsScript = """
        (() => {
            const doc = document.documentElement;
            const body = document.body || {};
            const scrollWidth = Math.max(doc.scrollWidth || 0, body.scrollWidth || 0, window.innerWidth || 0);
            const scrollHeight = Math.max(doc.scrollHeight || 0, body.scrollHeight || 0, window.innerHeight || 0);
            const viewportWidth = window.innerWidth || doc.clientWidth || 0;
            const viewportHeight = window.innerHeight || doc.clientHeight || 0;
            const originalX = window.scrollX || window.pageXOffset || 0;
            const originalY = window.scrollY || window.pageYOffset || 0;
            return {
                scrollWidth: scrollWidth,
                scrollHeight: scrollHeight,
                viewportWidth: viewportWidth,
                viewportHeight: viewportHeight,
                originalX: originalX,
                originalY: originalY
            };
        })()
        """

        wv.evaluateJavaScript(metricsScript) { [weak self, weak model, weak appModel] result, error in
            guard let self = self, self.currentCancelToken == token else { return }

            guard identity.matches(model) else {
                self.cancelCapture()
                model?.lastError = "페이지가 이동되어 캡처를 취소했습니다."
                return
            }

            if let error = error {
                self.cancelCapture()
                model?.lastError = "페이지 크기를 계산하지 못했습니다: \(error.localizedDescription)"
                return
            }

            guard let dict = result as? [String: Any],
                  let scrollHeightNum = dict["scrollHeight"] as? NSNumber,
                  let viewportWidthNum = dict["viewportWidth"] as? NSNumber,
                  let viewportHeightNum = dict["viewportHeight"] as? NSNumber,
                  let originalXNum = dict["originalX"] as? NSNumber,
                  let originalYNum = dict["originalY"] as? NSNumber else {
                self.cancelCapture()
                model?.lastError = "페이지 규격을 읽을 수 없습니다."
                return
            }

            let scrollHeight = CGFloat(scrollHeightNum.doubleValue)
            let viewportWidth = CGFloat(viewportWidthNum.doubleValue)
            let viewportHeight = CGFloat(viewportHeightNum.doubleValue)
            let originalX = CGFloat(originalXNum.doubleValue)
            let originalY = CGFloat(originalYNum.doubleValue)

            guard viewportWidth > 0, viewportHeight > 0, scrollHeight.isFinite else {
                self.cancelCapture()
                model?.lastError = "페이지 표시 영역 크기가 올바르지 않습니다."
                return
            }

            self.cleanupLock = token
            Task { @MainActor in
                await self.runScrollCaptureLoop(
                    token: token,
                    identity: identity,
                    scrollHeight: scrollHeight,
                    viewportWidth: viewportWidth,
                    viewportHeight: viewportHeight,
                    originalX: originalX,
                    originalY: originalY,
                    appModel: appModel,
                    model: model
                )
            }
        }
    }

    // MARK: - Page probing & waiting

    private struct PageProbe {
        let height: CGFloat
        let scrollY: CGFloat
        let pending: Int
        let loading: Bool
        let viewport: CGFloat

        /// The scroll position is the physical end of the document.
        var atBottom: Bool { scrollY + viewport >= height - 1.5 }
    }

    private enum SettleOutcome {
        case aborted
        case failed
        case done(PageProbe, timedOut: Bool)
    }

    /// `targetHeight` is in CSS px; the bitmap is `pixelWidth` x `pixelHeight` at `scale` output pixels per CSS pixel.
    private struct CapturePlan: Equatable {
        let targetHeight: CGFloat
        let stepCount: Int
        let scale: CGFloat
        let pixelWidth: Int
        let pixelHeight: Int
        /// The page is taller than what a safety cap allows: only its top part is captured.
        let heightTruncated: Bool
    }

    private enum HeightChange { case same, absorb, restart, unstable }

    /// Read-only page state (isolated world). Images near the viewport that are not complete, or whose decode has not
    /// finished, count as pending; `decode()` is only started for those, nothing else is requested or changed.
    private static let probeScript = #"""
    (function () {
      try {
        var d = document.documentElement, b = document.body || {};
        var vh = window.innerHeight || d.clientHeight || 0;
        var h = Math.max(d.scrollHeight || 0, b.scrollHeight || 0, vh);
        var st = window.__htdShotDecode || (window.__htdShotDecode = new WeakMap());
        var pending = 0, imgs = document.images, n = Math.min(imgs.length, 3000);
        for (var i = 0; i < n; i++) {
          var im = imgs[i], r = im.getBoundingClientRect();
          if (r.width < 2 || r.height < 2 || r.bottom < -vh * 0.5 || r.top > vh * 1.5) continue;
          if (!im.complete) { pending++; continue; }
          if (im.naturalWidth === 0 || typeof im.decode !== 'function') continue;
          var s = st.get(im);
          if (s === undefined) {
            st.set(im, 1);
            (function (el) { el.decode().then(function () { st.set(el, 2); }, function () { st.set(el, 2); }); })(im);
            pending++;
          } else if (s === 1) { pending++; }
        }
        return { h: h, y: window.scrollY || window.pageYOffset || 0, pending: pending, loading: document.readyState === 'loading', vh: vh };
      } catch (e) { return null; }
    })()
    """#

    private func probePage(_ wv: WKWebView) async -> PageProbe? {
        await withCheckedContinuation { (continuation: CheckedContinuation<PageProbe?, Never>) in
            wv.evaluateJavaScript(Self.probeScript, in: nil, in: Self.shotWorld) { result in
                guard case .success(let value) = result, let d = value as? [String: Any],
                      let h = (d["h"] as? NSNumber)?.doubleValue, let y = (d["y"] as? NSNumber)?.doubleValue,
                      h.isFinite, y.isFinite else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: PageProbe(
                    height: CGFloat(h), scrollY: CGFloat(y),
                    pending: (d["pending"] as? NSNumber)?.intValue ?? 0,
                    loading: (d["loading"] as? NSNumber)?.boolValue ?? false,
                    viewport: CGFloat((d["vh"] as? NSNumber)?.doubleValue ?? 0)))
            }
        }
    }

    /// Scrolls only the document that carries this capture's marker (see `markerScript`): never a newer page.
    private func scroll(_ wv: WKWebView, to y: CGFloat, token: UUID) {
        let js = "(function(){var s=window.__htdShot;if(!s||s.token!=='\(token.uuidString)')return;window.scrollTo({left:0,top:\(y),behavior:'instant'});})()"
        wv.evaluateJavaScript(js, in: nil, in: Self.shotWorld, completionHandler: nil)
    }

    /// Ownership marker: lives in the isolated world's global of ONE document (a new document starts without it, the page
    /// cannot see or forge it). It also remembers the scroll position of that very document.
    private static func markerScript(_ token: UUID) -> String {
        "(function(){window.__htdShot={token:'\(token.uuidString)',x:window.scrollX||0,y:window.scrollY||0};return 'ok';})()"
    }

    /// Restores hidden fixed/sticky elements (and optionally the scroll position) only if this document still carries the
    /// marker; the check and the restore run in one JS turn, so a navigation cannot slip in between.
    private static func cleanupScript(_ token: UUID, scroll: Bool, release: Bool) -> String {
        """
        (function(){
            var s = window.__htdShot;
            if (!s || s.token !== '\(token.uuidString)') return 'skip';
            var els = document.querySelectorAll('[data-htd-prev-visibility]');
            for (var i = 0; i < els.length; i++) {
                var el = els[i];
                var prev = el.getAttribute('data-htd-prev-visibility');
                el.style.visibility = (prev === 'visible') ? '' : prev;
                el.removeAttribute('data-htd-prev-visibility');
            }
            \(scroll ? "window.scrollTo({ left: s.x, top: s.y, behavior: 'instant' });" : "")
            \(release ? "delete window.__htdShot;" : "")
            return 'ok';
        })()
        """
    }

    private final class OnceFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var fired = false
        func claim() -> Bool { lock.lock(); defer { lock.unlock() }; if fired { return false }; fired = true; return true }
    }

    /// Runs a script in the capture world; nil on error, closed WebView or after `timeout` (the callback may never come).
    private func evalShot(_ wv: WKWebView, _ script: String, timeout: UInt64) async -> String? {
        await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            let once = OnceFlag()
            wv.evaluateJavaScript(script, in: nil, in: Self.shotWorld) { result in
                guard once.claim() else { return }
                if case .success(let value) = result { continuation.resume(returning: value as? String) }
                else { continuation.resume(returning: nil) }
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: timeout)
                if once.claim() { continuation.resume(returning: nil) }
            }
        }
    }

    /// Final page cleanup of a loop; the capture lock is released when it finished (or timed out), never earlier.
    private func finishLoop(wv: WKWebView, token: UUID, releaseFlags: Bool) {
        Task { @MainActor in
            _ = await self.evalShot(wv, Self.cleanupScript(token, scroll: true, release: true), timeout: Self.cleanupTimeoutNanos)
            if self.cleanupLock == token { self.cleanupLock = nil }
            // Only the capture that is still current clears the flags: a loop of an older capture never touches a newer one.
            if releaseFlags, self.currentCancelToken == token {
                self.currentCancelToken = nil
                self.activeModel = nil
                self.captureStatus = nil
            }
            if self.currentCancelToken == nil, !self.isPreviewing { self.isCapturing = false }
        }
    }

    /// Same checks as before every step of the old loop: cancelled -> notice, page/tab changed -> error.
    private func captureIsLive(token: UUID, identity: PageIdentity, model: LoginBrowserModel?) -> Bool {
        guard currentCancelToken == token, identity.matches(model) else {
            if currentCancelToken == token { model?.lastError = "페이지가 이동되었거나 탭이 바뀌어 캡처를 취소했습니다." }
            else { model?.notice = "전체 페이지 캡처를 취소했습니다." }
            return false
        }
        return true
    }

    /// Polls until the page is quiet (no pending images near the viewport, height unchanged, scroll position reached)
    /// for `quiet`, or `maxWait` has passed. Every poll re-checks the capture token and page identity.
    private func settle(wv: WKWebView, token: UUID, identity: PageIdentity, model: LoginBrowserModel?,
                        position: (y: CGFloat, viewportHeight: CGFloat)?, quiet: UInt64, maxWait: UInt64) async -> SettleOutcome {
        let start = DispatchTime.now().uptimeNanoseconds
        var quietSince = start
        var lastHeight: CGFloat?
        while true {
            guard captureIsLive(token: token, identity: identity, model: model) else { return .aborted }
            guard let probe = await probePage(wv) else { return .failed }
            guard captureIsLive(token: token, identity: identity, model: model) else { return .aborted }
            let now = DispatchTime.now().uptimeNanoseconds
            if let last = lastHeight, abs(probe.height - last) > 1 { quietSince = now }
            lastHeight = probe.height
            var positioned = true
            if let position = position {
                let reachable = min(position.y, max(0, probe.height - position.viewportHeight))
                positioned = abs(probe.scrollY - reachable) <= 1.5
            }
            if probe.pending > 0 || probe.loading || !positioned { quietSince = now }
            if now - quietSince >= quiet { return .done(probe, timedOut: false) }
            if now - start >= maxWait { return .done(probe, timedOut: true) }
            try? await Task.sleep(nanoseconds: Self.pollNanos)
        }
    }

    /// Scrolls through the page once, a little less than a viewport at a time, so lazy images load and the document reaches
    /// its real height; then waits at the bottom and returns to the top. Bounded by step count, per-step wait and a total
    /// budget (`timedOut` tells the capture that something did not finish). nil: cancelled / page lost (message already set).
    private func preloadPage(wv: WKWebView, token: UUID, identity: PageIdentity, model: LoginBrowserModel?,
                             viewportHeight: CGFloat, startHeight: CGFloat, fromY: CGFloat = 0) async -> (height: CGFloat, timedOut: Bool)? {
        let deadline = DispatchTime.now().uptimeNanoseconds + Self.preloadBudgetNanos
        let stride = max(viewportHeight * 0.8, 200)
        let reachLimit = Self.maxTotalHeight + viewportHeight
        var height = startHeight
        var timedOut = false
        var reachedBottom = false
        var y: CGFloat = max(0, fromY)
        var step = 0

        while step < Self.maxPreloadSteps {
            let now = DispatchTime.now().uptimeNanoseconds
            if now >= deadline { break }
            let visibleEnd = min(height, reachLimit)
            let percent = Int(min(1, (y + viewportHeight) / max(1, visibleEnd)) * 100)
            captureStatus = "이미지와 페이지 하단을 미리 불러오는 중입니다 (\(percent)%)..."
            scroll(wv, to: y, token: token)
            let atBottom = y + viewportHeight >= visibleEnd
            let outcome = await settle(
                wv: wv, token: token, identity: identity, model: model,
                position: (y, viewportHeight),
                quiet: atBottom ? Self.preloadBottomQuietNanos : Self.preloadQuietNanos,
                maxWait: min(deadline - now, atBottom ? Self.preloadBottomMaxNanos : Self.preloadStepMaxNanos))
            switch outcome {
            case .aborted: return nil
            case .failed:
                model?.lastError = "페이지 상태를 확인하지 못해 캡처를 중단했습니다."
                return nil
            case .done(let probe, let late):
                height = probe.height
                if late { timedOut = true }
            }
            if y + viewportHeight >= min(height, reachLimit) { reachedBottom = true; break }
            y += stride
            step += 1
        }
        if !reachedBottom { timedOut = true }

        captureStatus = "페이지 맨 위로 돌아가는 중입니다..."
        scroll(wv, to: 0, token: token)
        let outcome = await settle(wv: wv, token: token, identity: identity, model: model, position: (0, viewportHeight),
                                   quiet: Self.preloadQuietNanos, maxWait: Self.preloadStepMaxNanos)
        switch outcome {
        case .aborted: return nil
        case .failed:
            model?.lastError = "페이지 상태를 확인하지 못해 캡처를 중단했습니다."
            return nil
        case .done(let probe, let late):
            if late { timedOut = true }
            return (probe.height, timedOut)
        }
    }

    // MARK: - Capture plan

    /// Picks the output density and the captured height. The densest scale whose whole (capped) page fits the pixel budget
    /// wins, so ordinary long pages are captured to their end; only a page that does not fit even at the lowest scale
    /// (or passes the runaway cap) is cut off at the bottom and reported as partial. nil: one screen alone is too big.
    private static func makePlan(rawHeight: CGFloat, viewportWidth: CGFloat, viewportHeight: CGFloat, backingScale: CGFloat) -> CapturePlan? {
        let capped = max(1, min(rawHeight, Self.maxTotalHeight))
        let scales = [backingScale] + Self.pixelScaleSteps.filter { $0 < backingScale }
        func width(_ scale: CGFloat) -> Int { max(1, Int((viewportWidth * scale).rounded(.down))) }
        var scale = scales[scales.count - 1]
        for candidate in scales where width(candidate) * Int((capped * candidate).rounded(.up)) <= Self.maxTotalPixels {
            scale = candidate
            break
        }
        let pixelWidth = width(scale)
        let budgetHeight = (CGFloat(Self.maxTotalPixels / pixelWidth) / scale).rounded(.down)
        let targetHeight = min(capped, budgetHeight)
        guard targetHeight >= min(viewportHeight, capped) else { return nil }
        let stepCount = targetHeight <= viewportHeight ? 1 : Int(ceil(targetHeight / viewportHeight))
        return CapturePlan(targetHeight: targetHeight, stepCount: stepCount, scale: scale, pixelWidth: pixelWidth,
                           pixelHeight: max(1, min(Int((targetHeight * scale).rounded(.up)), Self.maxTotalPixels / pixelWidth)),
                           heightTruncated: targetHeight < rawHeight - 1.5)
    }

    private func classifyHeightChange(observed: CGFloat, rawHeight: CGFloat, plan: CapturePlan, viewportWidth: CGFloat,
                                      viewportHeight: CGFloat, backingScale: CGFloat, restartsLeft: Bool) -> HeightChange {
        guard abs(observed - rawHeight) > 1.5 else { return .same }
        let next = Self.makePlan(rawHeight: observed, viewportWidth: viewportWidth, viewportHeight: viewportHeight, backingScale: backingScale)
        // Growth beyond a safety cap does not change what can be captured.
        if next == plan { return .absorb }
        return restartsLeft ? .restart : .unstable
    }

    // MARK: - Capture loop

    private func runScrollCaptureLoop(
        token: UUID,
        identity: PageIdentity,
        scrollHeight: CGFloat,
        viewportWidth: CGFloat,
        viewportHeight: CGFloat,
        originalX: CGFloat,
        originalY: CGFloat,
        appModel: AppModel?,
        model: LoginBrowserModel?
    ) async {
        let wv = identity.webView
        let hideChromeScript = """
        (() => {
            const s = window.__htdShot;
            if (!s || s.token !== '\(token.uuidString)') return;
            const all = document.querySelectorAll('*');
            for (let i = 0; i < all.length; i++) {
                const el = all[i];
                const style = window.getComputedStyle(el);
                if (style.position === 'fixed' || style.position === 'sticky') {
                    if (!el.hasAttribute('data-htd-prev-visibility')) {
                        el.setAttribute('data-htd-prev-visibility', el.style.visibility || 'visible');
                        el.style.visibility = 'hidden';
                    }
                }
            }
        })()
        """

        // True once the finished capture was handed to the preview window: it keeps the capture busy flags.
        var handedToPreview = false

        defer {
            // Always restore scroll position and chrome visibility of the document this capture marked (also after a
            // cancel); the capture lock is held until that is done.
            self.finishLoop(wv: wv, token: token, releaseFlags: !handedToPreview)
        }

        // The plan (output density and captured height) is made before the first slice: the one output bitmap never
        // exceeds maxTotalPixels, whatever the page height becomes later.
        let backingScale = max(1, wv.window?.backingScaleFactor ?? 2)
        guard Self.makePlan(rawHeight: scrollHeight, viewportWidth: viewportWidth, viewportHeight: viewportHeight,
                            backingScale: backingScale) != nil else {
            model?.lastError = "화면이 너무 커서 전체 페이지 캡처의 메모리 한도를 넘습니다. 영역 캡처를 사용해 주세요."
            return
        }

        // The marker (and the original scroll position) is stored in this document before anything is scrolled or hidden.
        guard await evalShot(wv, Self.markerScript(token), timeout: Self.cleanupTimeoutNanos) == "ok",
              captureIsLive(token: token, identity: identity, model: model) else {
            if model?.lastError == nil { model?.lastError = "페이지 상태를 확인하지 못해 캡처를 중단했습니다." }
            return
        }

        // 1) Scroll through the page first: lazy images load, the real bottom appears.
        guard let preload = await preloadPage(wv: wv, token: token, identity: identity, model: model,
                                              viewportHeight: viewportHeight, startHeight: scrollHeight) else { return }
        var loadTimedOut = preload.timedOut
        var rawHeight = preload.height
        var restarts = 0
        var heightUnstable = false
        var misplaced = false
        var stoppedEarly = false
        var finished: (canvas: StitchCanvas, plan: CapturePlan)?
        let sliceDeadline = DispatchTime.now().uptimeNanoseconds + Self.sliceBudgetNanos

        // 2) Slices. If the document height changes while they are taken, the capture starts over (bounded).
        captureAttempts: while true {
            guard let plan = Self.makePlan(rawHeight: rawHeight, viewportWidth: viewportWidth, viewportHeight: viewportHeight,
                                           backingScale: backingScale),
                  let canvas = StitchCanvas(plan: plan, maxPixels: Self.maxTotalPixels) else {
                model?.lastError = "전체 페이지 이미지를 만들 메모리 한도를 넘었습니다. 영역 캡처를 사용해 주세요."
                return
            }
            var restartHeight: CGFloat?

            sliceLoop: for i in 0..<plan.stepCount {
                guard captureIsLive(token: token, identity: identity, model: model) else { return }
                // An endless page ends here with the part captured so far.
                if i > 0, DispatchTime.now().uptimeNanoseconds >= sliceDeadline {
                    stoppedEarly = true
                    break sliceLoop
                }

                if restarts > 0 {
                    self.captureStatus = "페이지 높이가 바뀌어 다시 캡처하는 중입니다 (\(i + 1)/\(plan.stepCount))..."
                } else {
                    self.captureStatus = "전체 페이지를 캡처하는 중입니다 (\(i + 1)/\(plan.stepCount))..."
                }

                // Slices follow each other without overlap; the last one is placed so that it ends exactly at the target
                // (which is the physical end of the document unless a safety cap applies).
                let scrollY: CGFloat
                if plan.stepCount == 1 {
                    scrollY = 0
                } else if i < plan.stepCount - 1 {
                    scrollY = CGFloat(i) * viewportHeight
                } else {
                    scrollY = max(0, plan.targetHeight - viewportHeight)
                }

                scroll(wv, to: scrollY, token: token)

                if i == 1 {
                    wv.evaluateJavaScript(hideChromeScript, in: nil, in: Self.shotWorld, completionHandler: nil)
                }

                // Images in this viewport complete/decoded, height stable, position reached; the last slice waits longer.
                let isLast = i == plan.stepCount - 1
                let outcome = await settle(
                    wv: wv, token: token, identity: identity, model: model,
                    position: (scrollY, viewportHeight),
                    quiet: isLast ? Self.lastSliceQuietNanos : Self.sliceQuietNanos,
                    maxWait: isLast ? Self.lastSliceMaxNanos : Self.sliceMaxNanos)
                var probe: PageProbe
                switch outcome {
                case .aborted: return
                case .failed:
                    model?.lastError = "페이지 상태를 확인하지 못해 캡처를 중단했습니다."
                    return
                case .done(let p, let late):
                    probe = p
                    if late { loadTimedOut = true }
                }

                switch classifyHeightChange(observed: probe.height, rawHeight: rawHeight, plan: plan, viewportWidth: viewportWidth,
                                            viewportHeight: viewportHeight, backingScale: backingScale,
                                            restartsLeft: restarts < Self.maxCaptureRestarts) {
                case .same: break
                case .absorb: rawHeight = probe.height
                case .unstable:
                    heightUnstable = true
                    rawHeight = probe.height
                case .restart:
                    restartHeight = probe.height
                    break sliceLoop
                }

                do {
                    // One slice at a time: drawn at the scroll position the page really had (the browser clamps it at the
                    // end of the document), then released. A scroll that moved during the snapshot retakes the slice.
                    var retakes = 2
                    while true {
                        let slice = try await takeSnapshotAsync(wv: wv)
                        guard captureIsLive(token: token, identity: identity, model: model) else { return }
                        guard let after = await probePage(wv) else {
                            model?.lastError = "페이지 상태를 확인하지 못해 캡처를 중단했습니다."
                            return
                        }
                        guard captureIsLive(token: token, identity: identity, model: model) else { return }
                        let steady = abs(after.scrollY - probe.scrollY) <= 1.5
                        if steady || retakes == 0 {
                            guard let cg = slice.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                                model?.lastError = "페이지 구간(\(i + 1)) 이미지를 읽지 못했습니다."
                                return
                            }
                            let expected = min(scrollY, max(0, after.height - viewportHeight))
                            if !steady || abs(after.scrollY - expected) > 1.5 { misplaced = true }
                            canvas.draw(slice: cg, scrollY: after.scrollY, viewportHeight: viewportHeight)
                            break
                        }
                        retakes -= 1
                        scroll(wv, to: scrollY, token: token)
                        switch await settle(wv: wv, token: token, identity: identity, model: model, position: (scrollY, viewportHeight),
                                            quiet: Self.sliceQuietNanos, maxWait: Self.sliceMaxNanos) {
                        case .aborted: return
                        case .failed:
                            model?.lastError = "페이지 상태를 확인하지 못해 캡처를 중단했습니다."
                            return
                        case .done(let p, let late):
                            probe = p
                            if late { loadTimedOut = true }
                        }
                    }
                } catch {
                    model?.lastError = "페이지 구간(\(i + 1)) 캡처 중 오류가 발생했습니다: \(error.localizedDescription)"
                    return
                }
            }

            // Height checked once more after the last slice: content appended meanwhile must not be missed, and an
            // uncapped capture must have ended at the physical bottom of the document.
            if restartHeight == nil, !stoppedEarly {
                if let end = await probePage(wv) {
                    guard captureIsLive(token: token, identity: identity, model: model) else { return }
                    switch classifyHeightChange(observed: end.height, rawHeight: rawHeight, plan: plan, viewportWidth: viewportWidth,
                                                viewportHeight: viewportHeight, backingScale: backingScale,
                                                restartsLeft: restarts < Self.maxCaptureRestarts) {
                    case .same:
                        if !plan.heightTruncated, !end.atBottom { misplaced = true }
                    case .absorb: rawHeight = end.height
                    case .unstable:
                        heightUnstable = true
                        rawHeight = end.height
                    case .restart: restartHeight = end.height
                    }
                }
            }

            if let newHeight = restartHeight {
                restarts += 1
                let oldHeight = rawHeight
                rawHeight = newHeight
                _ = await evalShot(wv, Self.cleanupScript(token, scroll: false, release: false), timeout: Self.cleanupTimeoutNanos)
                // The part that appeared since the preload is scrolled through as well, so its images are loaded.
                guard let again = await preloadPage(wv: wv, token: token, identity: identity, model: model,
                                                    viewportHeight: viewportHeight, startHeight: newHeight,
                                                    fromY: max(0, oldHeight - viewportHeight)) else { return }
                if again.timedOut { loadTimedOut = true }
                rawHeight = again.height
                continue captureAttempts
            }
            finished = (canvas, plan)
            break
        }

        guard let done = finished else { return }
        let canvas = done.canvas
        let plan = done.plan

        self.captureStatus = "캡처한 이미지를 연결하는 중..."
        guard let stitched = canvas.makeImage() else {
            model?.lastError = "전체 페이지 이미지를 연결하지 못했습니다."
            return
        }

        // Anything the safeguards or an unstable page left out is reported, never presented as a complete capture.
        var warnings: [String] = []
        var partialNote: String?
        if plan.heightTruncated || stoppedEarly {
            warnings.append(stoppedEarly ? "일부만 캡처됨 (시간 한도)" : "일부만 캡처됨 (크기 한도)")
            partialNote = stoppedEarly ? "시간 제한으로 일부만 포함" : "크기 제한으로 일부만 포함"
        }
        if heightUnstable {
            warnings.append("페이지 높이 변동")
            partialNote = partialNote.map { $0 + ", 페이지 높이 변동" } ?? "페이지 높이 변동"
        }
        if misplaced {
            warnings.append("구간 어긋남 가능")
        }
        if loadTimedOut {
            warnings.append("이미지 일부 미로딩")
        }

        guard let appModel = appModel, let model = model else { return }
        guard self.currentCancelToken == token, identity.matches(model) else {
            model.lastError = "저장 직전에 페이지가 바뀌어 캡처를 저장하지 않았습니다."
            return
        }

        // The preview works on a smaller copy while zoomed out; building it never blocks the main thread.
        self.captureStatus = "미리보기를 준비하는 중입니다..."
        let box = SendableImage(image: stitched)
        let proxyBox = await Task.detached(priority: .userInitiated) { () -> SendableImage? in
            Self.makePreviewProxy(box.image).map { SendableImage(image: $0) }
        }.value
        guard captureIsLive(token: token, identity: identity, model: model), wv.window != nil else { return }

        let title = model.pageTitle.isEmpty ? (identity.url?.host ?? "웹화면") : model.pageTitle
        let filename = "\(Self.sanitizeFilename(title))_전체스크롤_\(Self.timestampString()).png"
        let input = ScreenshotPreviewInput(
            image: stitched, proxy: proxyBox?.image, cssViewportWidth: viewportWidth,
            sliceCount: plan.stepCount, fileName: filename, warnings: warnings)

        let controller = ScreenshotPreviewController(input: input, folderProvider: { [weak appModel] in appModel?.destinationFolder ?? "" })
        controller.onCancel = { [weak self, weak model] in
            guard let self = self, self.currentCancelToken == token else { return }
            self.cancelCapture()
            model?.notice = "전체 페이지 캡처를 저장하지 않고 닫았습니다."
        }
        let sliceCount = plan.stepCount
        controller.onSave = { [weak self, weak model] data, folder, cropped in
            guard let self = self else { return nil }
            return self.commitPreview(data, folder: folder, filename: filename, cropped: cropped, partialNote: partialNote,
                                      sliceCount: sliceCount, token: token, identity: identity, model: model)
        }
        previewController = controller
        previewIdentity = identity
        isPreviewing = true
        handedToPreview = true
        captureStatus = "미리보기"
        previewTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkPreviewStillValid() }
        }
        controller.present(over: wv.window)
    }

    /// The preview is bound to the page it was captured from: another tab, navigation or a closed window ends it unsaved.
    private func checkPreviewStillValid() {
        guard previewController != nil, let identity = previewIdentity else { return }
        guard identity.matches(activeModel) else {
            let model = activeModel
            cancelCapture()
            model?.lastError = "탭이나 페이지가 바뀌어 미리보기를 닫고 저장하지 않았습니다."
            return
        }
    }

    /// Save pressed in the preview: writes the already encoded PNG (the captured image, never the live page) through
    /// `writeUnique`. Returns an error text to show in the preview (it stays open), or nil (saved, or capture ended).
    private func commitPreview(_ data: Data, folder: String, filename: String, cropped: Bool, partialNote: String?, sliceCount: Int,
                               token: UUID, identity: PageIdentity, model: LoginBrowserModel?) -> String? {
        guard currentCancelToken == token, let model = model, identity.matches(model) else {
            cancelCapture()
            model?.lastError = "저장 직전에 페이지가 바뀌어 캡처를 저장하지 않았습니다."
            return nil
        }
        do {
            let targetURL = try Self.writeUnique(data, folder: folder, preferredFilename: filename)
            cancelCapture()
            if cropped {
                let note = partialNote == nil ? "" : " (원본 캡처가 일부만 포함: \(partialNote ?? ""))"
                model.notice = "페이지 캡처에서 선택한 영역을 저장했습니다\(note): \(targetURL.lastPathComponent)"
            } else if let partialNote = partialNote {
                model.notice = "페이지 일부만 저장했습니다 (\(sliceCount)개 구간, \(partialNote)): \(targetURL.lastPathComponent)"
            } else {
                model.notice = "전체 페이지를 저장했습니다 (\(sliceCount)개 구간 연결): \(targetURL.lastPathComponent)"
            }
            model.lastError = nil
            return nil
        } catch {
            model.lastError = "전체 페이지 캡처 파일 저장에 실패했습니다: \(error.localizedDescription)"
            return "저장 실패: \(error.localizedDescription)"
        }
    }

    /// Lower-resolution copy of a big capture for smooth zoomed-out viewing (nil when the image is small enough).
    nonisolated static func makePreviewProxy(_ image: CGImage) -> CGImage? {
        let w = Double(image.width), h = Double(image.height)
        guard w > 0, h > 0 else { return nil }
        let scale = min(1.0, 1800.0 / w, (16_000_000.0 / (w * h)).squareRoot())
        guard scale < 0.98 else { return nil }
        let pw = max(1, Int((w * scale).rounded())), ph = max(1, Int((h * scale).rounded()))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: pw, height: ph))
        return ctx.makeImage()
    }

    private func takeSnapshotAsync(wv: WKWebView) async throws -> NSImage {
        try await withCheckedThrowingContinuation { continuation in
            wv.takeSnapshot(with: nil) { image, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else if let image = image {
                    continuation.resume(returning: image)
                } else {
                    continuation.resume(throwing: NSError(domain: "BrowserScreenshot", code: 1, userInfo: [NSLocalizedDescriptionKey: "스냅샷 이미지를 생성하지 못했습니다."]))
                }
            }
        }
    }

    // MARK: - Stitching & Retina Scaling

    /// The single output bitmap; slices are drawn into it as they arrive, each at its own scroll position (later slices
    /// cover the few overlapping rows of earlier ones).
    private final class StitchCanvas {
        private let context: CGContext
        private let pixelWidth: Int
        private let pixelHeight: Int
        private let scale: CGFloat
        /// Rows (from the top) that have been drawn; the image is cut there, so unreached rows never show as blank.
        private var drawnBottom = 0

        init?(plan: CapturePlan, maxPixels: Int) {
            guard plan.pixelWidth > 0, plan.pixelHeight > 0, plan.pixelWidth <= maxPixels / plan.pixelHeight,
                  let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(
                    data: nil, width: plan.pixelWidth, height: plan.pixelHeight, bitsPerComponent: 8, bytesPerRow: 0,
                    space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else { return nil }
            context.interpolationQuality = .high
            self.context = context
            self.pixelWidth = plan.pixelWidth
            self.pixelHeight = plan.pixelHeight
            self.scale = plan.scale
        }

        func draw(slice cgSlice: CGImage, scrollY: CGFloat, viewportHeight: CGFloat) {
            let top = min(max(0, Int((scrollY * scale).rounded(.down))), pixelHeight - 1)
            let height = max(1, Int((viewportHeight * scale).rounded(.up)))
            // In CGContext (0,0 is bottom-left); a slice reaching past the end is clipped, never squeezed.
            context.draw(cgSlice, in: CGRect(x: 0, y: pixelHeight - top - height, width: pixelWidth, height: height))
            drawnBottom = max(drawnBottom, min(pixelHeight, top + height))
        }

        func makeImage() -> CGImage? {
            guard drawnBottom > 0, let full = context.makeImage() else { return nil }
            if drawnBottom >= pixelHeight { return full }
            return full.cropping(to: CGRect(x: 0, y: 0, width: pixelWidth, height: drawnBottom))
        }
    }

    // MARK: - Utilities

    /// PNG straight from the CGImage (no intermediate TIFF/bitmap-rep copy).
    nonisolated static func pngData(from image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    public static func sanitizeFilename(_ raw: String) -> String {
        let invalidCharacters = CharacterSet(charactersIn: "/\\?%*|\"<>:")
            .union(.controlCharacters)
            .union(.newlines)
        let filtered = raw.components(separatedBy: invalidCharacters).joined(separator: "_")
        let trimmed = filtered.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "웹화면"
        }
        return String(trimmed.prefix(60))
    }

    public static func timestampString() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return formatter.string(from: Date())
    }

    /// Creates the file with O_CREAT|O_EXCL, so a name that exists (or appears concurrently, from this app or any other
    /// process) is never overwritten: the next " (n)" name is tried instead. No check-then-write gap, no replace.
    public static func writeUnique(_ data: Data, folder: String, preferredFilename: String) throws -> URL {
        let folderURL = URL(fileURLWithPath: folder, isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)

        let ext = (preferredFilename as NSString).pathExtension
        let nameWithoutExt = (preferredFilename as NSString).deletingPathExtension

        for counter in 0..<1000 {
            let name = counter == 0 ? preferredFilename : "\(nameWithoutExt) (\(counter)).\(ext)"
            let url = folderURL.appendingPathComponent(name)
            let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
            if fd < 0 {
                if errno == EEXIST { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
            do {
                try handle.write(contentsOf: data)
                try handle.close()
                return url
            } catch {
                try? handle.close()
                unlink(url.path)   // our own, exclusively created, incomplete file
                throw error
            }
        }
        throw CocoaError(.fileWriteFileExists)
    }
}

// MARK: - Selection overlay

/// Dimmed drag-to-select layer added as a subview of the web view (same bounds, flipped like the page).
@MainActor
final class ScreenshotSelectionView: NSView {
    var onSelect: ((NSRect) -> Void)?
    var onCancel: (() -> Void)?
    /// Instruction text shown until a drag starts (the screenshot default is kept when nothing sets it).
    var hintText = "캡처할 영역을 드래그하세요 · Esc: 취소"
    /// Editor mode only (nil for screenshots): outlined rectangles in overlay coordinates; a plain click inside one
    /// reports its index through `onPickOutline`, a drag still goes to `onSelect`. The page cannot scroll meanwhile.
    var outlines: [NSRect]?
    var onPickOutline: ((Int) -> Void)?

    private var anchor: NSPoint?
    private var current: NSPoint?
    private var finished = false

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    private var selection: NSRect? {
        guard let a = anchor, let c = current else { return nil }
        let r = NSRect(x: min(a.x, c.x), y: min(a.y, c.y), width: abs(a.x - c.x), height: abs(a.y - c.y))
        return r.intersection(bounds)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Tab switched away / view removed while selecting: nothing may be captured.
        if window == nil, !finished { finished = true; onCancel?() }
    }

    override func draw(_ dirtyRect: NSRect) {
        let dim = NSColor.black.withAlphaComponent(0.4)
        dim.setFill()
        if let sel = selection, sel.width > 0, sel.height > 0 {
            let path = NSBezierPath(rect: bounds)
            path.appendRect(sel)
            path.windingRule = .evenOdd
            path.fill()
            NSColor.white.setStroke()
            let border = NSBezierPath(rect: sel.insetBy(dx: 0.5, dy: 0.5))
            border.lineWidth = 1
            border.stroke()
            let label = "\(Int(sel.width)) × \(Int(sel.height))" as NSString
            label.draw(at: NSPoint(x: sel.minX + 4, y: max(2, sel.minY - 18)), withAttributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                .foregroundColor: NSColor.white,
                .backgroundColor: NSColor.black.withAlphaComponent(0.6)
            ])
        } else {
            bounds.fill()
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 14, weight: .semibold),
                .foregroundColor: NSColor.white,
                .paragraphStyle: style
            ]
            let hint = hintText as NSString
            let box = hint.boundingRect(with: NSSize(width: max(40, bounds.width - 60), height: bounds.height),
                                        options: [.usesLineFragmentOrigin], attributes: attrs)
            hint.draw(in: NSRect(x: 30, y: bounds.midY - box.height / 2, width: max(40, bounds.width - 60), height: box.height + 2),
                      withAttributes: attrs)
        }
        if let outlines = outlines {
            NSColor.systemOrange.setStroke()
            for rect in outlines {
                let path = NSBezierPath(rect: rect.insetBy(dx: 1, dy: 1))
                path.lineWidth = 2
                path.setLineDash([5, 3], count: 2, phase: 0)
                path.stroke()
            }
        }
    }

    override func scrollWheel(with event: NSEvent) {
        if outlines == nil { super.scrollWheel(with: event) }
    }

    override func mouseDown(with event: NSEvent) {
        anchor = convert(event.locationInWindow, from: nil)
        current = anchor
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard anchor != nil else { return }
        current = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard anchor != nil else { return }
        current = convert(event.locationInWindow, from: nil)
        let rect = selection
        if let rect = rect, rect.width >= 8, rect.height >= 8, !finished {
            finished = true
            onSelect?(rect)
        } else if let outlines = outlines, !finished, (rect?.width ?? 0) < 8, (rect?.height ?? 0) < 8,
                  let point = current,
                  let hit = outlines.enumerated().filter({ $0.element.contains(point) })
                      .min(by: { $0.element.width * $0.element.height < $1.element.width * $1.element.height })?.offset {
            finished = true
            onPickOutline?(hit)
        } else {
            // A click or a tiny drag is not a selection: stay in selection mode.
            anchor = nil
            current = nil
            needsDisplay = true
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53, !finished {
            finished = true
            onCancel?()
        } else {
            super.keyDown(with: event)
        }
    }
}

// MARK: - Full page preview (crop / size / save)

/// CGImage is immutable; this only lets it cross into the background tasks that render or measure the PNG.
struct SendableImage: @unchecked Sendable {
    let image: CGImage
}

struct ScreenshotPreviewInput {
    let image: CGImage
    let proxy: CGImage?
    /// CSS width of the captured viewport: the image is `image.width / cssViewportWidth` device pixels per CSS pixel.
    let cssViewportWidth: CGFloat
    let sliceCount: Int
    let fileName: String
    let warnings: [String]
}

/// Crop + resample + PNG, all CoreGraphics/ImageIO. Without resampling the cropped image shares the capture's pixels.
enum ScreenshotRender {
    /// Above this many output pixels the size is a sample-based estimate instead of a full encode.
    static let exactPixelLimit = 12_000_000
    private static let sampleBandPixels = 1_500_000

    struct Options {
        let original: Int
        let recommended: Int
        let smaller: Int?
        let minimum: Int
    }

    /// Output widths for a crop `cropWidth` device pixels wide. Never above the crop (no upscaling). The recommended
    /// width keeps body text readable: 1200 (1600 for Retina-sized sources) but never below the crop's native CSS width.
    static func options(cropWidth: Int, pixelScale: CGFloat) -> Options {
        let cw = max(1, cropWidth)
        let nativeCSS = Int((CGFloat(cw) / max(1, pixelScale)).rounded(.up))
        let ideal = cw > 2000 ? 1600 : 1200
        let recommended = min(cw, max(ideal, nativeCSS))
        let minimum = min(cw, 64)
        let smallerCandidate = max(minimum, Int(Double(recommended) * 0.6))
        return Options(original: cw, recommended: recommended,
                       smaller: smallerCandidate < recommended ? smallerCandidate : nil, minimum: minimum)
    }

    /// Output rows `rowStart..<rowStart+rowCount` of the cropped image scaled to `outWidth` x `outHeight`.
    static func rows(source: CGImage, crop: CGRect, outWidth: Int, outHeight: Int, rowStart: Int, rowCount: Int) -> CGImage? {
        guard rowCount > 0, rowStart >= 0, rowStart + rowCount <= outHeight, outWidth > 0 else { return nil }
        if outWidth == Int(crop.width) && outHeight == Int(crop.height) {
            return source.cropping(to: CGRect(x: crop.minX, y: crop.minY + CGFloat(rowStart), width: crop.width, height: CGFloat(rowCount)))
        }
        guard let cropped = source.cropping(to: crop),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: outWidth, height: rowCount, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        // The whole output is laid out so that the wanted rows fall into this (shorter) context.
        ctx.draw(cropped, in: CGRect(x: 0, y: CGFloat(rowStart + rowCount - outHeight),
                                     width: CGFloat(outWidth), height: CGFloat(outHeight)))
        return ctx.makeImage()
    }

    /// The final PNG (ImageIO's lossless PNG encoder; it exposes no compression level).
    static func png(source: CGImage, crop: CGRect, outWidth: Int, outHeight: Int) -> Data? {
        guard let image = rows(source: source, crop: crop, outWidth: outWidth, outHeight: outHeight, rowStart: 0, rowCount: outHeight) else { return nil }
        return BrowserScreenshotManager.pngData(from: image)
    }

    /// Actual encoded size for modest outputs; for huge ones the average of three encoded bands (top/middle/bottom)
    /// scaled to the full height, reported as an estimate. Never holds more than one band or one modest image.
    static func measure(source: CGImage, crop: CGRect, outWidth: Int, outHeight: Int) -> (bytes: Int, exact: Bool)? {
        if outWidth * outHeight <= exactPixelLimit {
            guard let data = png(source: source, crop: crop, outWidth: outWidth, outHeight: outHeight) else { return nil }
            return (data.count, true)
        }
        let band = max(16, min(outHeight, sampleBandPixels / max(1, outWidth)))
        var total = 0, sampledRows = 0
        for start in [0, (outHeight - band) / 2, outHeight - band] {
            if Task.isCancelled { return nil }
            guard let image = rows(source: source, crop: crop, outWidth: outWidth, outHeight: outHeight, rowStart: start, rowCount: band),
                  let data = BrowserScreenshotManager.pngData(from: image) else { return nil }
            total += data.count
            sampledRows += band
        }
        guard sampledRows > 0 else { return nil }
        return (Int(Double(total) / Double(sampledRows) * Double(outHeight)), false)
    }
}

/// Scrollable, zoomable picture of the capture with a crop rectangle: drag outside = new selection, drag inside = move,
/// drag an edge/corner handle = resize, arrow keys = nudge. A click never clears it (Reset/crop/restore do). The
/// selection is kept in image pixels, top-left origin, always inside the image and at least `minSide` wide/high.
@MainActor
final class ScreenshotPreviewCanvasView: NSView {
    private(set) var image: CGImage?
    private var proxy: CGImage?
    private(set) var zoom: CGFloat = 1
    private(set) var selection: CGRect?
    var onSelectionChange: (() -> Void)?
    var interactionEnabled = true {
        didSet { if !interactionEnabled { endDrag() } }
    }

    private struct Edges: Equatable {
        var left = false, right = false, top = false, bottom = false
    }
    private enum Drag {
        case create(anchor: CGPoint)
        case move(grab: CGPoint)
        case resize(fixed: CGRect, edges: Edges)
    }
    private var drag: Drag?
    private var selectionBeforeDrag: CGRect?
    private var trackingArea: NSTrackingArea?
    private static let minSide: CGFloat = 8
    private static let handleTolerance: CGFloat = 7

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area = trackingArea { removeTrackingArea(area) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .cursorUpdate, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    /// Replaces the shown picture (crop / restore). The selection belongs to the old picture and is dropped.
    func setImages(full: CGImage, proxy: CGImage?) {
        image = full
        self.proxy = proxy
        selection = nil
        endDrag()
        setZoom(zoom, keepCenter: false)
        onSelectionChange?()
    }

    /// Late reduced copy, accepted only while `forImage` is still the shown picture (a stale result is dropped).
    func setProxy(_ newProxy: CGImage?, forImage: CGImage) {
        guard let image = image, image === forImage else { return }
        proxy = newProxy
        needsDisplay = true
    }

    /// Drops the pixels (and every callback) once the preview is closed.
    func releaseImages() {
        image = nil
        proxy = nil
        selection = nil
        onSelectionChange = nil
        drag = nil
        needsDisplay = true
    }

    func clearSelection() {
        guard selection != nil else { return }
        selection = nil
        endDrag()
        needsDisplay = true
        onSelectionChange?()
    }

    private func endDrag() {
        drag = nil
        selectionBeforeDrag = nil
    }

    func setZoom(_ newZoom: CGFloat, keepCenter: Bool = true) {
        guard let image = image else { return }
        let visible = visibleRect
        let center = zoom > 0 ? CGPoint(x: visible.midX / zoom, y: visible.midY / zoom) : .zero
        zoom = max(0.001, newZoom)
        setFrameSize(NSSize(width: max(1, CGFloat(image.width) * zoom), height: max(1, CGFloat(image.height) * zoom)))
        if keepCenter {
            scroll(NSPoint(x: max(0, center.x * zoom - visible.width / 2), y: max(0, center.y * zoom - visible.height / 2)))
        }
        needsDisplay = true
    }

    private func viewRect(_ r: CGRect) -> NSRect {
        NSRect(x: r.minX * zoom, y: r.minY * zoom, width: r.width * zoom, height: r.height * zoom)
    }

    private func imagePoint(_ p: NSPoint) -> CGPoint {
        guard let image = image, zoom > 0 else { return .zero }
        return CGPoint(x: min(max(0, p.x / zoom), CGFloat(image.width)), y: min(max(0, p.y / zoom), CGFloat(image.height)))
    }

    /// Rectangle between two image points, on whole pixels, clamped inside the image (too small ones are rejected on mouse-up).
    private func makeRect(_ x0: CGFloat, _ y0: CGFloat, _ x1: CGFloat, _ y1: CGFloat) -> CGRect {
        guard let image = image else { return .zero }
        let iw = CGFloat(image.width), ih = CGFloat(image.height)
        func span(_ a: CGFloat, _ b: CGFloat, limit: CGFloat) -> (CGFloat, CGFloat) {
            var lo = min(a, b).rounded(.down), hi = max(a, b).rounded(.up)
            lo = min(max(0, lo), limit); hi = min(max(0, hi), limit)
            return (lo, hi)
        }
        let (left, right) = span(x0, x1, limit: iw)
        let (top, bottom) = span(y0, y1, limit: ih)
        return CGRect(x: left, y: top, width: right - left, height: bottom - top)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0.16, alpha: 1).setFill()
        dirtyRect.fill()
        guard let image = image, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let full = NSRect(x: 0, y: 0, width: CGFloat(image.width) * zoom, height: CGFloat(image.height) * zoom)
        let backing = window?.backingScaleFactor ?? 2
        // The reduced copy is enough while the picture is shown at or below its resolution.
        var shown = image
        if let proxy = proxy, CGFloat(proxy.width) >= full.width * backing { shown = proxy }

        ctx.saveGState()
        ctx.clip(to: dirtyRect)
        ctx.interpolationQuality = .high
        // Only the strip under the dirty rect is cut from the (possibly tens of thousands of pixels tall) picture and drawn,
        // so no huge image or huge flipped transform reaches the compositor. Source rows are top-left based like the view.
        let sx = CGFloat(shown.width) / max(1, full.width), sy = CGFloat(shown.height) / max(1, full.height)
        let want = dirtyRect.intersection(full)
        let src = CGRect(x: want.minX * sx, y: want.minY * sy, width: want.width * sx, height: want.height * sy)
            .insetBy(dx: -2, dy: -2).integral
            .intersection(CGRect(x: 0, y: 0, width: shown.width, height: shown.height))
        if !want.isEmpty, !src.isEmpty, let piece = shown.cropping(to: src) {
            let dest = CGRect(x: src.minX / sx, y: src.minY / sy, width: src.width / sx, height: src.height / sy)
            ctx.translateBy(x: dest.minX, y: dest.maxY)
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(piece, in: CGRect(x: 0, y: 0, width: dest.width, height: dest.height))
        }
        ctx.restoreGState()

        guard let sel = selection else { return }
        let r = viewRect(sel)
        let dim = NSBezierPath(rect: full)
        dim.append(NSBezierPath(rect: r))
        dim.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.5).setFill()
        dim.fill()
        NSColor.white.setStroke()
        let outline = NSBezierPath(rect: r.insetBy(dx: 0.5, dy: 0.5))
        outline.lineWidth = 1
        outline.stroke()
        NSColor.systemBlue.setStroke()
        let dashed = NSBezierPath(rect: r.insetBy(dx: 1.5, dy: 1.5))
        dashed.lineWidth = 1
        dashed.setLineDash([4, 3], count: 2, phase: 0)
        dashed.stroke()
        // Eight handles (corners + edge middles), always drawn so they stay visible on small selections.
        let xs = [r.minX, r.midX, r.maxX], ys = [r.minY, r.midY, r.maxY]
        for (xi, x) in xs.enumerated() {
            for (yi, y) in ys.enumerated() where !(xi == 1 && yi == 1) {
                let handle = NSRect(x: x - 4, y: y - 4, width: 8, height: 8)
                NSColor.white.setFill()
                handle.fill()
                NSColor.systemBlue.setStroke()
                NSBezierPath(rect: handle.insetBy(dx: 0.5, dy: 0.5)).stroke()
            }
        }
    }

    // MARK: Hit testing / cursors

    /// Edges grabbed at view point `p`: corners hit two, edge middles one. Near a small rectangle's handles the
    /// tolerance is capped so the inside stays movable.
    private func edgeHit(_ p: NSPoint, in r: NSRect) -> Edges? {
        let tol = Self.handleTolerance
        guard p.x >= r.minX - tol, p.x <= r.maxX + tol, p.y >= r.minY - tol, p.y <= r.maxY + tol else { return nil }
        let tx = min(tol, r.width / 3), ty = min(tol, r.height / 3)
        var e = Edges()
        if abs(p.x - r.minX) <= max(tx, 3) { e.left = true } else if abs(p.x - r.maxX) <= max(tx, 3) { e.right = true }
        if abs(p.y - r.minY) <= max(ty, 3) { e.top = true } else if abs(p.y - r.maxY) <= max(ty, 3) { e.bottom = true }
        return (e.left || e.right || e.top || e.bottom) ? e : nil
    }

    private static func cursor(for e: Edges) -> NSCursor {
        let horizontal = e.left || e.right, vertical = e.top || e.bottom
        if horizontal && vertical {
            if #available(macOS 15.0, *) {
                let pos: NSCursor.FrameResizePosition
                switch (e.left, e.top) {
                case (true, true): pos = .topLeft
                case (false, true): pos = .topRight
                case (true, false): pos = .bottomLeft
                case (false, false): pos = .bottomRight
                }
                return NSCursor.frameResize(position: pos, directions: .all)
            }
            return .crosshair
        }
        return horizontal ? .resizeLeftRight : .resizeUpDown
    }

    private func applyCursor(at p: NSPoint) {
        if let drag = drag {
            switch drag {
            case .create: NSCursor.crosshair.set()
            case .move: NSCursor.closedHand.set()
            case .resize(_, let edges): Self.cursor(for: edges).set()
            }
            return
        }
        guard interactionEnabled, let sel = selection else { NSCursor.crosshair.set(); return }
        let r = viewRect(sel)
        if let hit = edgeHit(p, in: r) { Self.cursor(for: hit).set() }
        else if r.contains(p) { NSCursor.openHand.set() }
        else { NSCursor.crosshair.set() }
    }

    override func cursorUpdate(with event: NSEvent) {
        applyCursor(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        applyCursor(at: convert(event.locationInWindow, from: nil))
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        guard interactionEnabled, image != nil else { return }
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        let ip = imagePoint(p)
        selectionBeforeDrag = selection
        if let sel = selection {
            let r = viewRect(sel)
            if let hit = edgeHit(p, in: r) {
                drag = .resize(fixed: sel, edges: hit)
            } else if r.contains(p) {
                drag = .move(grab: CGPoint(x: ip.x - sel.minX, y: ip.y - sel.minY))
            } else {
                drag = .create(anchor: ip)
            }
        } else {
            drag = .create(anchor: ip)
        }
        applyCursor(at: p)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let drag = drag, let image = image else { return }
        autoscroll(with: event)
        let ip = imagePoint(convert(event.locationInWindow, from: nil))
        switch drag {
        case .create(let anchor):
            selection = makeRect(anchor.x, anchor.y, ip.x, ip.y)
        case .move(let grab):
            guard let sel = selection else { return }
            let x = min(max(0, (ip.x - grab.x).rounded()), CGFloat(image.width) - sel.width)
            let y = min(max(0, (ip.y - grab.y).rounded()), CGFloat(image.height) - sel.height)
            selection = CGRect(x: x, y: y, width: sel.width, height: sel.height)
        case .resize(let fixed, let e):
            selection = resized(fixed, edges: e, to: ip)
        }
        needsDisplay = true
        onSelectionChange?()
    }

    /// Moves only the grabbed edges to `ip`; the opposite edges stay put and the result never gets thinner than `minSide`.
    private func resized(_ fixed: CGRect, edges e: Edges, to ip: CGPoint) -> CGRect {
        var minX = fixed.minX, maxX = fixed.maxX, minY = fixed.minY, maxY = fixed.maxY
        if e.left { minX = min(ip.x.rounded(), maxX - Self.minSide) }
        if e.right { maxX = max(ip.x.rounded(), minX + Self.minSide) }
        if e.top { minY = min(ip.y.rounded(), maxY - Self.minSide) }
        if e.bottom { maxY = max(ip.y.rounded(), minY + Self.minSide) }
        let iw = CGFloat(image?.width ?? 0), ih = CGFloat(image?.height ?? 0)
        minX = max(0, minX); minY = max(0, minY); maxX = min(iw, maxX); maxY = min(ih, maxY)
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    override func mouseUp(with event: NSEvent) {
        guard drag != nil else { return }
        let previous = selectionBeforeDrag
        endDrag()
        if let sel = selection, sel.width >= Self.minSide, sel.height >= Self.minSide {
            // keep the rectangle
        } else {
            // A click or a tiny drag never destroys the previous rectangle (or leaves a too small one): it comes back.
            selection = previous
        }
        needsDisplay = true
        onSelectionChange?()
        applyCursor(at: convert(event.locationInWindow, from: nil))
    }

    // MARK: Keyboard

    /// Arrow keys nudge the selection by one image pixel (ten with Shift); without a selection they scroll as usual.
    override func keyDown(with event: NSEvent) {
        guard interactionEnabled, drag == nil, let image = image, let sel = selection,
              event.modifierFlags.intersection([.command, .option, .control]).isEmpty else {
            super.keyDown(with: event)
            return
        }
        let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
        var dx: CGFloat = 0, dy: CGFloat = 0
        switch event.keyCode {
        case 123: dx = -step
        case 124: dx = step
        case 126: dy = -step
        case 125: dy = step
        default:
            super.keyDown(with: event)
            return
        }
        let x = min(max(0, sel.minX + dx), CGFloat(image.width) - sel.width)
        let y = min(max(0, sel.minY + dy), CGFloat(image.height) - sel.height)
        let moved = CGRect(x: x, y: y, width: sel.width, height: sel.height)
        guard moved != sel else { return }
        selection = moved
        scrollToVisible(viewRect(moved).insetBy(dx: -12, dy: -12))
        needsDisplay = true
        onSelectionChange?()
    }
}

/// Native preview window for a finished full-page capture: whole-image view with zoom/fit, crop rectangle (Crop applies it
/// to the preview, Restore brings the untouched capture back), output width (original / recommended / smaller / custom,
/// never upscaled), size shown, Save or Cancel. Everything after Crop (size, estimate, PNG) works on the cropped picture;
/// `input.image` is the untouched capture and is never modified. Owned by the capture manager;
/// it reports through closures that capture the manager weakly, and `teardown()` never calls them.
@MainActor
final class ScreenshotPreviewController: NSObject, NSWindowDelegate, NSTextFieldDelegate {
    /// Cancel button, Escape or the window's close button.
    var onCancel: (() -> Void)?
    /// (PNG data, folder, cropped) -> error text to show (preview stays open) or nil.
    var onSave: ((Data, String, Bool) -> String?)?

    private enum WidthKind: Int { case original = 0, recommended, smaller, custom }
    private enum FitMode { case width, whole, manual }

    private let input: ScreenshotPreviewInput
    private let folderProvider: () -> String
    /// The picture shown and saved: `input.image` or a crop of it (a crop shares the capture's pixels, nothing is copied).
    private var source: CGImage?
    private var cropApplied = false
    private let window: NSWindow
    private let canvas = ScreenshotPreviewCanvasView()
    private let scrollView = NSScrollView()

    private let infoLabel = NSTextField(labelWithString: "")
    private let zoomLabel = NSTextField(labelWithString: "")
    private let selectionLabel = NSTextField(labelWithString: "")
    private let summaryLabel = NSTextField(labelWithString: "")
    private let pathLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let widthPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let widthField = NSTextField()
    private var controlButtons: [NSButton] = []
    private var cropButton: NSButton?
    private var restoreButton: NSButton?
    private var resetSelectionButton: NSButton?
    private let saveButton = NSButton(title: "저장", target: nil, action: nil)
    private let cancelButton = NSButton(title: "취소", target: nil, action: nil)

    private var widthKind: WidthKind = .recommended
    private var customWidth = 0
    private var fitMode: FitMode = .width
    private var shownFolder: String
    private var closed = false
    private var saving = false
    private var estimateGeneration = 0
    private var estimateTask: Task<Void, Never>?
    private var estimateText: String?
    private var saveTask: Task<Void, Never>?
    private var proxyGeneration = 0
    private var proxyTask: Task<Void, Never>?

    init(input: ScreenshotPreviewInput, folderProvider: @escaping () -> String) {
        self.input = input
        self.folderProvider = folderProvider
        self.source = input.image
        self.shownFolder = folderProvider()
        self.window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 780),
                               styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init()
        buildUI()
    }

    // MARK: Presenting / closing

    func present(over parent: NSWindow?) {
        window.contentView?.layoutSubtreeIfNeeded()
        canvas.setImages(full: input.image, proxy: input.proxy)
        canvas.onSelectionChange = { [weak self] in self?.selectionChanged() }
        applyFit(.width)
        updateInfo()
        refreshAll()
        if let screen = (parent?.screen ?? NSScreen.main) {
            let vis = screen.visibleFrame
            var frame = window.frame
            frame.size.width = min(frame.width, vis.width * 0.92)
            frame.size.height = min(frame.height, vis.height * 0.92)
            window.setFrame(frame, display: false)
        }
        window.center()
        if let parent = parent { parent.addChildWindow(window, ordered: .above) }
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(canvas)
    }

    /// Releases the window and the image; calls nothing back.
    func teardown() {
        guard !closed else { return }
        closed = true
        onCancel = nil
        onSave = nil
        estimateTask?.cancel()
        saveTask?.cancel()
        proxyGeneration += 1
        proxyTask?.cancel()
        window.delegate = nil
        canvas.releaseImages()
        source = nil
        window.parent?.removeChildWindow(window)
        window.close()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        cancelTapped()
        return false
    }

    func windowDidResize(_ notification: Notification) {
        if fitMode != .manual { applyFit(fitMode) }
    }

    @objc private func cancelTapped() {
        guard !closed else { return }
        onCancel?()
    }

    // MARK: UI

    private func makeButton(_ title: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .small
        controlButtons.append(button)
        return button
    }

    private func buildUI() {
        window.title = "전체 페이지 캡처 미리보기"
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 700, height: 560)
        let content = NSView()
        window.contentView = content

        infoLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        infoLabel.lineBreakMode = .byTruncatingTail
        infoLabel.setContentCompressionResistancePriority(.init(250), for: .horizontal)

        var rows: [NSView] = [infoLabel]
        if !input.warnings.isEmpty {
            // Short state badge (partial capture etc.); no sentences.
            let badge = NSTextField(labelWithString: "⚠︎ " + input.warnings.joined(separator: " · "))
            badge.font = .systemFont(ofSize: 12, weight: .medium)
            badge.textColor = .systemOrange
            badge.lineBreakMode = .byTruncatingTail
            badge.setContentCompressionResistancePriority(.init(250), for: .horizontal)
            rows.append(badge)
        }

        zoomLabel.font = .systemFont(ofSize: 11)
        selectionLabel.font = .systemFont(ofSize: 11)
        selectionLabel.lineBreakMode = .byTruncatingTail
        selectionLabel.setContentCompressionResistancePriority(.init(250), for: .horizontal)
        let toolbar = NSStackView(views: [
            makeButton("폭에 맞춤", #selector(fitWidthTapped)), makeButton("전체 보기", #selector(fitWholeTapped)),
            makeButton("100%", #selector(actualTapped)), makeButton("−", #selector(zoomOutTapped)), makeButton("+", #selector(zoomInTapped)),
            zoomLabel
        ])
        toolbar.orientation = .horizontal
        toolbar.spacing = 6
        rows.append(toolbar)

        let resetButton = makeButton("선택 해제", #selector(resetSelectionTapped))
        let crop = makeButton("자르기", #selector(cropTapped))
        let restore = makeButton("원본으로", #selector(restoreTapped))
        resetSelectionButton = resetButton
        cropButton = crop
        restoreButton = restore
        let cropSpacer = NSView()
        cropSpacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let cropRow = NSStackView(views: [selectionLabel, cropSpacer, resetButton, crop, restore])
        cropRow.orientation = .horizontal
        cropRow.spacing = 6
        rows.append(cropRow)

        scrollView.documentView = canvas
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = NSColor(white: 0.16, alpha: 1)
        scrollView.borderType = .lineBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.setContentHuggingPriority(.init(1), for: .vertical)
        scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true
        rows.append(scrollView)

        widthPopup.target = self
        widthPopup.action = #selector(widthPopupChanged)
        widthPopup.controlSize = .small
        widthField.delegate = self
        widthField.alignment = .right
        widthField.controlSize = .small
        widthField.translatesAutoresizingMaskIntoConstraints = false
        widthField.widthAnchor.constraint(equalToConstant: 64).isActive = true
        let widthTitle = NSTextField(labelWithString: "가로 폭")
        widthTitle.font = .systemFont(ofSize: 12)
        let pxLabel = NSTextField(labelWithString: "px")
        pxLabel.font = .systemFont(ofSize: 12)
        summaryLabel.font = .systemFont(ofSize: 12, weight: .medium)
        summaryLabel.lineBreakMode = .byTruncatingTail
        summaryLabel.setContentCompressionResistancePriority(.init(250), for: .horizontal)
        let output = NSStackView(views: [widthTitle, widthPopup, widthField, pxLabel, summaryLabel])
        output.orientation = .horizontal
        output.spacing = 6
        rows.append(output)

        pathLabel.font = .systemFont(ofSize: 11)
        pathLabel.textColor = .secondaryLabelColor
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.setContentCompressionResistancePriority(.init(250), for: .horizontal)
        rows.append(pathLabel)

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.init(250), for: .horizontal)
        cancelButton.target = self
        cancelButton.action = #selector(cancelTapped)
        cancelButton.keyEquivalent = "\u{1b}"
        saveButton.target = self
        saveButton.action = #selector(saveTapped)
        saveButton.keyEquivalent = "\r"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let bottom = NSStackView(views: [statusLabel, spacer, cancelButton, saveButton])
        bottom.orientation = .horizontal
        bottom.spacing = 8
        rows.append(bottom)

        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor)
        ])
    }

    // MARK: Zoom

    private var backing: CGFloat { window.backingScaleFactor }

    private func applyFit(_ mode: FitMode) {
        fitMode = mode
        guard mode != .manual, let image = source else { return }
        // A crop can shrink the document and hide a scroller; settle the layout so the size measured below is the final one.
        scrollView.layoutSubtreeIfNeeded()
        var available = scrollView.contentSize
        if scrollView.scrollerStyle == .legacy {
            available.width -= NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
        }
        let widthFit = max(0.001, (available.width - 2) / CGFloat(image.width))
        let heightFit = max(0.001, (available.height - 2) / CGFloat(image.height))
        canvas.setZoom(mode == .width ? min(widthFit, 1 / backing) : min(widthFit, heightFit, 1 / backing), keepCenter: false)
        // Explicit origin (not the constrained scroll(to:)): the old clip origin may lie past the end of the smaller document.
        scrollView.contentView.setBoundsOrigin(.zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        scrollView.contentView.needsDisplay = true
        canvas.needsDisplay = true
        updateZoomLabel()
    }

    private func setManualZoom(_ zoom: CGFloat) {
        fitMode = .manual
        canvas.setZoom(min(max(zoom, 0.002), 4 / backing))
        updateZoomLabel()
    }

    private func updateZoomLabel() {
        zoomLabel.stringValue = "배율 \(Int((canvas.zoom * backing * 100).rounded()))%"
    }

    @objc private func fitWidthTapped() { applyFit(.width) }
    @objc private func fitWholeTapped() { applyFit(.whole) }
    @objc private func actualTapped() { setManualZoom(1 / backing) }
    @objc private func zoomInTapped() { setManualZoom(canvas.zoom * 1.25) }
    @objc private func zoomOutTapped() { setManualZoom(canvas.zoom / 1.25) }
    @objc private func resetSelectionTapped() {
        guard !saving else { return }
        canvas.clearSelection()
    }

    // MARK: Crop / output size

    /// Device pixels per CSS pixel of the capture; cropping does not resample, so it is the same for every crop.
    private var pixelScale: CGFloat { CGFloat(input.image.width) / max(1, input.cssViewportWidth) }

    /// Bounds of the picture that is shown now (the capture or its crop).
    private var fullRect: CGRect { CGRect(x: 0, y: 0, width: source?.width ?? 0, height: source?.height ?? 0) }

    /// The selection if Crop may use it: at least 8 x 8 px, inside the shown picture and not the whole picture.
    private func croppableSelection() -> CGRect? {
        guard !closed, let sel = canvas.selection else { return nil }
        let r = sel.integral.intersection(fullRect)
        guard !r.isNull, r.width >= 8, r.height >= 8, r != fullRect else { return nil }
        return r
    }

    private func updateInfo() {
        guard let image = source else { return }
        var text = "\(image.width) × \(image.height) px"
        if cropApplied { text += " · 원본 \(input.image.width) × \(input.image.height)" }
        infoLabel.stringValue = text
    }

    private func updateCropButtons() {
        cropButton?.isEnabled = !saving && croppableSelection() != nil
        restoreButton?.isEnabled = !saving && cropApplied
        resetSelectionButton?.isEnabled = !saving && canvas.selection != nil
    }

    /// Shows `image` (a crop, or the untouched capture again) and drops the selection of the previous picture. A late
    /// reduced copy for an old picture is discarded; a crop gets its own, built in the background.
    private func show(_ image: CGImage, proxy: CGImage?, cropped: Bool) {
        proxyGeneration += 1
        proxyTask?.cancel()
        proxyTask = nil
        source = image
        cropApplied = cropped
        canvas.setImages(full: image, proxy: proxy)
        applyFit(fitMode == .manual ? .whole : fitMode)
        updateInfo()
        refreshAll()
        if cropped, proxy == nil { rebuildProxy(for: image) }
    }

    private func rebuildProxy(for image: CGImage) {
        let generation = proxyGeneration
        let box = SendableImage(image: image)
        proxyTask = Task { [weak self] in
            guard let self = self else { return }
            let made = await self.runDetached { BrowserScreenshotManager.makePreviewProxy(box.image).map { SendableImage(image: $0) } }
            guard !Task.isCancelled, !self.closed, generation == self.proxyGeneration, self.source === box.image else { return }
            self.canvas.setProxy(made?.image, forImage: box.image)
        }
    }

    @objc private func cropTapped() {
        guard !saving, let image = source, let rect = croppableSelection() else { return }
        guard let cropped = image.cropping(to: rect) else {
            setStatus("자르기 실패", error: true)
            return
        }
        setStatus("")
        show(cropped, proxy: nil, cropped: true)
    }

    @objc private func restoreTapped() {
        guard !saving, cropApplied else { return }
        setStatus("")
        show(input.image, proxy: input.proxy, cropped: false)
    }

    private func currentCrop() -> CGRect {
        guard let sel = canvas.selection else { return fullRect }
        let r = sel.integral.intersection(fullRect)
        return (!r.isNull && r.width >= 8 && r.height >= 8) ? r : fullRect
    }

    private func outputSize() -> (w: Int, h: Int) {
        let crop = currentCrop()
        let cw = max(1, Int(crop.width)), ch = max(1, Int(crop.height))
        let o = ScreenshotRender.options(cropWidth: cw, pixelScale: pixelScale)
        var w: Int
        switch widthKind {
        case .original: w = o.original
        case .recommended: w = o.recommended
        case .smaller: w = o.smaller ?? o.recommended
        case .custom: w = min(max(customWidth, o.minimum), cw)
        }
        w = min(max(w, 1), cw)
        let h = w == cw ? ch : max(1, Int((Double(ch) * Double(w) / Double(cw)).rounded()))
        return (w, h)
    }

    private func selectionChanged() {
        refreshAll()
    }

    private func refreshAll() {
        guard !closed else { return }
        let crop = currentCrop()
        let cw = Int(crop.width), ch = Int(crop.height)
        if canvas.selection != nil, crop != fullRect {
            selectionLabel.stringValue = "선택 \(cw) × \(ch) px"
        } else {
            selectionLabel.stringValue = "\(cropApplied ? "잘라낸 영역" : "전체") \(cw) × \(ch) px"
        }
        updateCropButtons()

        let o = ScreenshotRender.options(cropWidth: cw, pixelScale: pixelScale)
        if widthKind == .smaller, o.smaller == nil { widthKind = .recommended }
        widthPopup.removeAllItems()
        func add(_ title: String, _ kind: WidthKind) {
            widthPopup.addItem(withTitle: title)
            widthPopup.lastItem?.tag = kind.rawValue
        }
        add("원본 (\(o.original) px)", .original)
        add("권장 (\(o.recommended) px)", .recommended)
        if let smaller = o.smaller { add("작게 (\(smaller) px)", .smaller) }
        add("직접 입력", .custom)
        widthPopup.selectItem(withTag: widthKind.rawValue)

        let size = outputSize()
        widthField.stringValue = "\(size.w)"
        summaryLabel.stringValue = "\(size.w) × \(size.h) px · 계산 중…"
        pathLabel.stringValue = shownFolder
        scheduleEstimate(size: size, crop: crop, selectedWidth: cw, selectedHeight: ch)
    }

    @objc private func widthPopupChanged() {
        guard let tag = widthPopup.selectedItem?.tag, let kind = WidthKind(rawValue: tag) else { return }
        widthKind = kind
        if kind == .custom {
            customWidth = outputSize().w
            window.makeFirstResponder(widthField)
        }
        refreshAll()
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard !closed, (obj.object as? NSTextField) === widthField else { return }
        let typed = Int(widthField.stringValue.trimmingCharacters(in: .whitespaces))
        if let typed = typed, typed > 0 {
            customWidth = typed
            widthKind = .custom
        }
        refreshAll()
    }

    /// Debounced, off the main thread, newest request wins: a result that is no longer current is dropped.
    private func scheduleEstimate(size: (w: Int, h: Int), crop: CGRect, selectedWidth: Int, selectedHeight: Int) {
        estimateGeneration += 1
        let generation = estimateGeneration
        estimateTask?.cancel()
        estimateTask = nil
        guard !saving, let image = source else { return }
        let box = SendableImage(image: image)
        let prefix = "\(size.w) × \(size.h) px"
        estimateTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled, let self = self, !self.closed, generation == self.estimateGeneration else { return }
            let result = await self.runDetached {
                ScreenshotRender.measure(source: box.image, crop: crop, outWidth: size.w, outHeight: size.h)
            }
            guard !Task.isCancelled, !self.closed, generation == self.estimateGeneration else { return }
            if let result = result {
                let bytes = ByteCountFormatter.string(fromByteCount: Int64(result.bytes), countStyle: .file)
                self.summaryLabel.stringValue = result.exact
                    ? "\(prefix) · PNG \(bytes)"
                    : "\(prefix) · PNG 약 \(bytes)"
            } else {
                self.summaryLabel.stringValue = "\(prefix) · 크기 계산 실패"
            }
        }
    }

    private func runDetached<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        let work = Task.detached(priority: .utility, operation: body)
        return await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
    }

    // MARK: Save

    private func setStatus(_ text: String, error: Bool = false) {
        statusLabel.stringValue = text
        statusLabel.textColor = error ? .systemRed : .secondaryLabelColor
    }

    private func setSaving(_ on: Bool) {
        saving = on
        canvas.interactionEnabled = !on
        saveButton.isEnabled = !on
        widthPopup.isEnabled = !on
        widthField.isEnabled = !on
        controlButtons.forEach { $0.isEnabled = !on }
        updateCropButtons()
    }

    @objc private func saveTapped() {
        guard !closed, !saving, let image = source else { return }
        let folder = folderProvider()
        guard !folder.isEmpty else {
            setStatus("저장 폴더 없음", error: true)
            return
        }
        if folder != shownFolder {
            shownFolder = folder
            refreshAll()
            setStatus("저장 폴더가 바뀌었습니다")
            return
        }
        let crop = currentCrop()
        let size = outputSize()
        let cropped = cropApplied || crop != fullRect
        estimateGeneration += 1
        estimateTask?.cancel()
        setSaving(true)
        setStatus("PNG 생성 중…")
        let box = SendableImage(image: image)
        saveTask = Task { [weak self] in
            guard let self = self else { return }
            let data = await self.runDetached {
                ScreenshotRender.png(source: box.image, crop: crop, outWidth: size.w, outHeight: size.h)
            }
            guard !Task.isCancelled, !self.closed else { return }
            guard let data = data else {
                self.setSaving(false)
                self.setStatus("PNG 생성 실패", error: true)
                self.refreshAll()
                return
            }
            self.setStatus("저장 중…")
            // On success the manager closes this window (and ends the capture) from inside the call.
            if let message = self.onSave?(data, folder, cropped), !self.closed {
                self.setSaving(false)
                self.setStatus(message, error: true)
                self.refreshAll()
            }
        }
    }
}

// MARK: - 광고 영역 숨기기 편집기

/// Toolbar 광고 label editor. Uses the same native selection overlay as the area screenshot. A drag picks ONE DOM
/// element inside/overlapping the selection (selector computed by isolated-world JS, never a stored rectangle); a click
/// on an outlined (already hidden) element removes just that rule. Rules are CSS `display:none`: new ones with a stable
/// `#id`/`.class` anchor and a sane size/structure are kept for the whole exact hostname (with a structural fingerprint
/// checked on every other page); so are elements that are/hold an identifiable ad iframe (host+path), which are matched by
/// that iframe identity plus a region guard instead; the rest stay exact-page only. Legacy exact-page rules whose selector qualifies are
/// promoted to the host when their original page is opened. No request is blocked or changed. Entering/cancelling
/// persists nothing; only add/remove/promotion writes.
@MainActor
final class BrowserAdHideManager: ObservableObject {
    static let shared = BrowserAdHideManager()
    static let world = WKContentWorld.world(name: "HttpsDownAdHide")

    @Published private(set) var isEditing = false

    private struct Context {
        let wv: WKWebView
        let identity: BrowserScreenshotManager.PageIdentity
        let key: String
        let host: String?
        let pageURL: String
        let token: UUID
        weak var model: LoginBrowserModel?
        weak var appModel: AppModel?
    }

    private var ctx: Context?
    private var overlay: ScreenshotSelectionView?
    private var escapeMonitor: Any?
    /// What the editor listed at entry: legacy exact-page rules first, then same-host rules (outline index = position here).
    private var shownPage: [String] = []
    private var shownSite: [AdHideSiteEntry] = []
    private var outlineIndex: [Int] = []
    /// True while a JS selection / editor refresh is in flight: add/remove are ignored (Escape and tab switch still work).
    private var busy = false

    private init() {}

    private static let hint = "광고 숨기기 편집\n숨길 부분을 드래그하면 그 안(또는 겹치는) 요소 1개만 숨깁니다. 안정적으로 찾을 수 있으면 같은 사이트의 다른 페이지에서도 숨기고, 아니면 이 페이지에서만 숨깁니다. 서버 요청은 바뀌지 않습니다.\n주황 점선 = 이미 숨긴 요소: 클릭하면 해제\nEsc 또는 ‘광고’ 다시 클릭: 종료 (스크롤은 종료 후)"

    private static func pageString(_ url: URL?) -> String? {
        guard let url = url, var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        c.fragment = nil
        return c.string
    }

    func toggle(appModel: AppModel, model: LoginBrowserModel) {
        if isEditing { exit(reapply: true, notice: "광고 숨김 편집을 종료했습니다."); return }
        guard !BrowserScreenshotManager.shared.isCapturing else { return }
        guard let wv = model.webView, !model.isShowingHome, wv.window != nil,
              let key = BrowserPreferences.adHidePageKey(wv.url), let page = Self.pageString(wv.url),
              wv.bounds.width >= 40, wv.bounds.height >= 40 else {
            model.lastError = "숨김 영역을 지정할 수 있는 웹 페이지(http/https)가 열려 있지 않습니다."
            return
        }
        let token = UUID()
        ctx = Context(wv: wv, identity: .init(webView: wv, model: model), key: key, host: BrowserPreferences.adHideSiteHost(wv.url), pageURL: page, token: token,
                      model: model, appModel: appModel)
        isEditing = true
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53, let self = self, MainActor.assumeIsolated({ self.isEditing }) else { return event }
            MainActor.assumeIsolated { self.exit(reapply: true, notice: "광고 숨김 편집을 종료했습니다.") }
            return nil
        }
        showEditor()
    }

    /// The tab lost its place or its page changed: the editor ends; this page's rules are put back if it is still the same page.
    func cancel(for model: LoginBrowserModel, reapply: Bool) {
        if ctx?.model === model { exit(reapply: reapply, notice: nil) }
    }

    private func sameDocument(_ c: Context) -> Bool {
        guard let m = c.model else { return false }
        return m.webView === c.wv && m.sessionToken == c.identity.sessionToken && m.generation == c.identity.generation
            && BrowserPreferences.adHidePageKey(c.wv.url) == c.key
    }

    private func usable(_ c: Context) -> Bool { sameDocument(c) && c.identity.matches(c.model) }

    private func tearDownOverlay() {
        overlay?.onSelect = nil
        overlay?.onCancel = nil
        overlay?.onPickOutline = nil
        overlay?.removeFromSuperview()
        overlay = nil
    }

    private func exit(reapply: Bool, notice: String?) {
        guard let c = ctx else { return }
        if let monitor = escapeMonitor { NSEvent.removeMonitor(monitor) }
        escapeMonitor = nil
        tearDownOverlay()
        ctx = nil
        shownPage = []
        shownSite = []
        outlineIndex = []
        busy = false
        isEditing = false
        if reapply, sameDocument(c), let app = c.appModel {
            applyRules(wv: c.wv, app: app, key: c.key, host: c.host, page: c.pageURL) { _ in }
        }
        if let notice = notice, let m = c.model { m.notice = notice }
    }

    private func staleExit(_ token: UUID) {
        guard ctx?.token == token else { return }
        let model = ctx?.model
        exit(reapply: false, notice: nil)
        model?.lastError = "페이지가 바뀌어 광고 숨김 편집을 종료했습니다."
    }

    /// Reveals this page's hidden elements, measures their live rectangles, and shows the overlay with outlines.
    private func showEditor() {
        guard let c = ctx, let app = c.appModel else { return }
        guard usable(c) else { staleExit(c.token); return }
        let pageSels = app.preferences.adHideSelectors(forKey: c.key)
        let siteEntries = c.host.map { app.preferences.adHideSiteEntries(forHost: $0) } ?? []
        let sels = pageSels + siteEntries.map { $0.selector }
        let script = AdHideScript.make("enter", page: c.pageURL, sels: pageSels, viewW: c.wv.bounds.width, site: siteEntries)
        let started = c.token
        busy = true
        c.wv.evaluateJavaScript(script, in: nil, in: Self.world) { [weak self] result in
            guard let self = self, self.ctx?.token == started, let c = self.ctx else { return }
            guard self.usable(c) else { self.staleExit(c.token); return }
            var value: Any?
            if case .success(let v) = result { value = v }
            guard let list = value as? [[String: Any]] else {
                self.exit(reapply: false, notice: nil)
                c.model?.lastError = "이 페이지에서는 광고 숨김 편집을 시작할 수 없습니다."
                return
            }
            self.shownPage = pageSels
            self.shownSite = siteEntries
            let wv = c.wv
            self.tearDownOverlay()
            let ov = ScreenshotSelectionView(frame: wv.bounds)
            ov.autoresizingMask = [.width, .height]
            ov.hintText = Self.hint
            wv.addSubview(ov)
            var rects: [NSRect] = []
            self.outlineIndex = []
            for item in list.prefix(2 * BrowserPreferences.maxAdHideSelectorsPerPage) {
                guard let i = (item["i"] as? NSNumber)?.intValue, i >= 0, i < sels.count,
                      let x = (item["x"] as? NSNumber)?.doubleValue, let y = (item["y"] as? NSNumber)?.doubleValue,
                      let w = (item["w"] as? NSNumber)?.doubleValue, let h = (item["h"] as? NSNumber)?.doubleValue,
                      [x, y, w, h].allSatisfy({ $0.isFinite }), w > 0, h > 0 else { continue }
                rects.append(wv.convert(NSRect(x: x, y: y, width: w, height: h), to: ov))
                self.outlineIndex.append(i)
            }
            ov.outlines = rects
            let token = c.token
            ov.onCancel = { [weak self] in
                guard let self = self, self.ctx?.token == token else { return }
                self.exit(reapply: true, notice: "광고 숨김 편집을 종료했습니다.")
            }
            ov.onSelect = { [weak self, weak ov] rect in
                guard let self = self, let ov = ov, self.ctx?.token == token else { return }
                self.add(ov.convert(rect, to: wv).intersection(wv.bounds))
            }
            ov.onPickOutline = { [weak self] idx in
                guard let self = self, self.ctx?.token == token, idx < self.outlineIndex.count else { return }
                self.remove(self.outlineIndex[idx])
            }
            self.overlay = ov
            self.busy = false
            wv.window?.makeFirstResponder(ov)
        }
    }

    private func add(_ rect: NSRect) {
        guard !busy, let c = ctx, let app = c.appModel, let model = c.model else { return }
        guard usable(c), rect.width.isFinite, rect.height.isFinite, rect.width > 0, rect.height > 0 else { staleExit(c.token); return }
        busy = true
        let beforePage = shownPage, beforeSite = shownSite
        let script = AdHideScript.make("add", page: c.pageURL, sels: beforePage + beforeSite.map { $0.selector },
                                       viewW: c.wv.bounds.width, rect: rect)
        c.wv.evaluateJavaScript(script, in: nil, in: Self.world) { [weak self] result in
            guard let self = self, self.ctx?.token == c.token else { return }
            guard self.usable(c) else { self.staleExit(c.token); return }
            var value: Any?
            if case .success(let v) = result { value = v }
            let d = value as? [String: Any]
            if let sel = d?["sel"] as? String, BrowserPreferences.isValidAdHideSelector(sel) {
                // Rules changed since the editor listed them (stale async result): save nothing, refresh the list.
                guard self.currentRules(app, c) == (beforePage, beforeSite) else { self.showEditor(); return }
                let fp = d?["fp"] as? String ?? ""
                let fpOK = BrowserPreferences.isValidAdHideFingerprint(fp)
                let classicOK = d?["dom"] as? Bool == true && BrowserPreferences.isDomainAnchoredSelector(sel)
                let siteEntry = fpOK ? Self.siteEntry(selector: sel, fp: fp, classicOK: classicOK, item: d) : nil
                if let host = c.host, let entry = siteEntry {
                    if app.preferences.setAdHideSiteEntries(beforeSite + [entry], forHost: host) {
                        model.lastError = nil
                        model.notice = "요소 1개를 \(host)의 다른 페이지에서도 숨기도록 저장했습니다. 편집을 종료하면 숨겨집니다. (서버 요청은 바뀌지 않음)"
                    } else {
                        model.lastError = app.preferences.errorMessage ?? "숨김 영역을 저장하지 못했습니다."
                    }
                } else if app.preferences.setAdHideSelectors(beforePage + [sel], forKey: c.key) {
                    model.lastError = nil
                    model.notice = "안정적인 기준(고유 id/class, 상위 영역, 광고 iframe 출처)이 없거나 영역이 커서 이 페이지에서만 숨기도록 저장했습니다. 편집을 종료하면 숨겨집니다."
                } else {
                    model.lastError = app.preferences.errorMessage ?? "숨김 영역을 저장하지 못했습니다."
                }
            } else {
                switch d?["err"] as? String {
                case "dup": model.lastError = "이미 숨김 목록에 있는 영역입니다. 주황 점선 영역을 클릭하면 해제됩니다."
                case "none": model.lastError = "선택한 영역에서 숨길 수 있는 요소를 찾지 못했습니다. 페이지 전체 크기의 영역은 숨길 수 없습니다."
                default: model.lastError = "선택한 요소를 안정적으로 다시 찾을 수 없어 숨기지 않았습니다."
                }
            }
            self.showEditor()
        }
    }

    /// Host rule for a live element, or nil when it only qualifies for its exact page. Classic anchored rules stay exactly as
    /// before; otherwise an element that is (or holds) an ad iframe with a usable `host/path` and passed the script's
    /// region guard becomes a provider-identified rule. `item` is the script's result (`dom`, `id`, `up`, `idDom`).
    private static func siteEntry(selector: String, fp: String, classicOK: Bool, item: [String: Any]?) -> AdHideSiteEntry? {
        var entry = AdHideSiteEntry(selector: selector, fp: fp)
        if !classicOK {
            // No own anchor: the provider identity and/or the stable slot (container) descriptor; neither -> page only.
            // The script derives `slot` for every candidate (also when `dom` is true), so an ancestor-anchored iframe keeps it.
            let slot = BrowserPreferences.adHideSlot(fromJSON: item?["slot"])
            var ident: String?, up: Int?
            if item?["idDom"] as? Bool == true, let id = item?["id"] as? String, let u = (item?["up"] as? NSNumber)?.intValue {
                ident = id
                up = u
            }
            guard ident != nil || slot != nil else { return nil }
            entry = AdHideSiteEntry(selector: selector, fp: fp, ident: ident, up: up, slot: slot)
        }
        return BrowserPreferences.isValidAdHideSiteEntry(entry) ? entry : nil
    }

    private func currentRules(_ app: AppModel, _ c: Context) -> ([String], [AdHideSiteEntry]) {
        (app.preferences.adHideSelectors(forKey: c.key), c.host.map { app.preferences.adHideSiteEntries(forHost: $0) } ?? [])
    }

    /// Removes one listed rule from the scope it belongs to (page rule -> page list, host rule -> host list).
    private func remove(_ index: Int) {
        guard !busy, let c = ctx, let app = c.appModel, let model = c.model else { return }
        let total = shownPage.count + shownSite.count
        guard usable(c), index >= 0, index < total else { staleExit(c.token); return }
        guard currentRules(app, c) == (shownPage, shownSite) else { showEditor(); return }
        let saved: Bool
        if index < shownPage.count {
            var next = shownPage
            next.remove(at: index)
            saved = app.preferences.setAdHideSelectors(next, forKey: c.key)
        } else if let host = c.host {
            var next = shownSite
            next.remove(at: index - shownPage.count)
            saved = app.preferences.setAdHideSiteEntries(next, forHost: host)
        } else {
            saved = false
        }
        if saved {
            model.lastError = nil
            model.notice = "선택한 숨김을 해제했습니다."
        } else {
            model.lastError = app.preferences.errorMessage ?? "숨김 해제를 저장하지 못했습니다."
        }
        showEditor()
    }

    /// Applies this page's own rules plus its host's rules (the latter fingerprint-checked in the page script).
    /// `done` gets the number of host rules that matched an element but were skipped because it looked different.
    /// `force` also runs with no rules left: the script then only removes the previously injected style (deleted rules).
    private func applyRules(wv: WKWebView, app: AppModel, key: String, host: String?, page: String, force: Bool = false,
                            done: @escaping (Int) -> Void) {
        let pageSels = app.preferences.adHideSelectors(forKey: key)
        let site = host.map { app.preferences.adHideSiteEntries(forHost: $0) } ?? []
        guard force || !pageSels.isEmpty || !site.isEmpty else { done(0); return }
        let script = AdHideScript.make("apply", page: page, sels: pageSels, viewW: 0, site: site)
        wv.evaluateJavaScript(script, in: nil, in: Self.world) { [weak app, weak wv] result in
            var skipped = 0
            if case .success(let v) = result, let d = v as? [String: Any] {
                skipped = (d["skip"] as? NSNumber)?.intValue ?? 0
                // Provider-identified rules found on the live page get their slot descriptor (with branch metadata) stored, same page only.
                if let host = host, let app = app, let wv = wv, BrowserPreferences.adHidePageKey(wv.url) == key,
                   let mig = d["mig"] as? [[String: Any]], !mig.isEmpty {
                    var slots: [String: AdHideSlot] = [:]
                    for item in mig {
                        guard let i = (item["i"] as? NSNumber)?.intValue, i >= 0, i < site.count, site[i].slot?.k == nil,
                              let slot = BrowserPreferences.adHideSlot(fromJSON: item["slot"]) else { continue }
                        slots[site[i].selector] = slot
                    }
                    if !slots.isEmpty { app.preferences.attachAdHideSlots(slots, forHost: host) }
                }
            }
            done(skipped)
        }
    }

    /// Legacy exact-page rules of the page that was just opened: selectors whose live element is either classic-anchored
    /// or an identifiable ad iframe region, and passes the size/structure guard, move to this hostname (one transactional
    /// write); everything else stays page-only. Rules whose element is not on this page (e.g. an ad slot that only exists
    /// on another article) stay legacy until their own page is opened.
    /// `sourceKey` is the legacy rule being promoted (the current page's own, or one associated with this exact host);
    /// `key` stays the CURRENT page key the async navigation guard binds to.
    private func promoteLegacy(model: LoginBrowserModel, wv: WKWebView, key: String, sourceKey: String, host: String?, page: String,
                               gen: Int, session: Int, then: @escaping () -> Void) {
        guard let host = host, let app = model.appModel else { then(); return }
        let candidates = app.preferences.adHideSelectors(forKey: sourceKey)
        guard !candidates.isEmpty else { then(); return }
        wv.evaluateJavaScript(AdHideScript.make("promote", page: page, sels: candidates, viewW: 0), in: nil, in: Self.world) {
            [weak self, weak model, weak wv] result in
            guard let self = self, let model = model, let wv = wv, self.ctx?.wv !== wv, model.webView === wv,
                  model.generation == gen, model.sessionToken == session,
                  BrowserPreferences.adHidePageKey(wv.url) == key, let app = model.appModel else { return }
            if case .success(let v) = result, let list = v as? [[String: Any]] {
                let entries = list.prefix(BrowserPreferences.maxAdHideSelectorsPerPage).compactMap { item -> AdHideSiteEntry? in
                    guard let s = item["s"] as? String, let fp = item["fp"] as? String,
                          candidates.contains(s), BrowserPreferences.isValidAdHideFingerprint(fp) else { return nil }
                    let classicOK = item["dom"] as? Bool == true && BrowserPreferences.isDomainAnchoredSelector(s)
                    return Self.siteEntry(selector: s, fp: fp, classicOK: classicOK, item: item)
                }
                if !entries.isEmpty { app.preferences.promoteAdHidePageSelectors(Array(entries), pageKey: sourceKey, host: host) }
            }
            then()
        }
    }

    /// Promotes each source legacy rule in turn (one at a time, each its own transactional write).
    private func promoteSources(_ sources: [String], model: LoginBrowserModel, wv: WKWebView, key: String, host: String?, page: String,
                                gen: Int, session: Int, then: @escaping () -> Void) {
        guard let first = sources.first else { then(); return }
        promoteLegacy(model: model, wv: wv, key: key, sourceKey: first, host: host, page: page, gen: gen, session: session) {
            [weak self, weak model, weak wv] in
            guard let self = self, let model = model, let wv = wv else { return }
            self.promoteSources(Array(sources.dropFirst()), model: model, wv: wv, key: key, host: host, page: page,
                                gen: gen, session: session, then: then)
        }
    }

    /// Rule management sheet saved a change: an open editor ends without touching the page (its list would be stale), then
    /// every open page gets exactly its remaining saved rules (a deleted rule's element is shown again).
    func refreshAfterRuleChange(tabs: [LoginBrowserModel]) {
        if isEditing { exit(reapply: false, notice: nil) }
        for model in tabs {
            guard let wv = model.webView, !model.isShowingHome, let app = model.appModel,
                  let key = BrowserPreferences.adHidePageKey(wv.url), let page = Self.pageString(wv.url) else { continue }
            applyRules(wv: wv, app: app, key: key, host: BrowserPreferences.adHideSiteHost(wv.url), page: page, force: true) { _ in }
        }
    }

    /// Page finished loading: re-applies this page's and its host's rules (and once more shortly after, for late-built ads).
    func reapply(for model: LoginBrowserModel) {
        guard let wv = model.webView, ctx?.wv !== wv, !model.isShowingHome, let app = model.appModel,
              let key = BrowserPreferences.adHidePageKey(wv.url), let page = Self.pageString(wv.url) else { return }
        let host = BrowserPreferences.adHideSiteHost(wv.url)
        let gen = model.generation, session = model.sessionToken
        func same(_ model: LoginBrowserModel?, _ wv: WKWebView?) -> Bool {
            guard let model = model, let wv = wv else { return false }
            return model.webView === wv && model.generation == gen && model.sessionToken == session
                && BrowserPreferences.adHidePageKey(wv.url) == key
        }
        // The exact original page was opened: remember its host so other pages of that host can promote what is left of it.
        if let host = host, !app.preferences.adHideSelectors(forKey: key).isEmpty {
            app.preferences.associateAdHidePage(key: key, host: host)
        }
        func legacySources(_ app: AppModel) -> [String] {
            var keys = app.preferences.adHideSelectors(forKey: key).isEmpty ? [] : [key]
            if let host = host { keys += app.preferences.adHideLegacyKeys(forHost: host).filter { $0 != key } }
            return keys
        }
        let hasRules = !legacySources(app).isEmpty
            || !(host.map { app.preferences.adHideSiteEntries(forHost: $0) } ?? []).isEmpty
        guard hasRules else { return }
        applyRules(wv: wv, app: app, key: key, host: host, page: page) { _ in }
        // Two passes: ad iframes are built late, so a legacy rule whose iframe was not there yet gets a second look.
        func pass(after delay: UInt64, onlyIfLegacyLeft: Bool) {
            Task { @MainActor [weak self, weak model, weak wv] in
                try? await Task.sleep(nanoseconds: delay)
                guard let self = self, let model = model, let wv = wv, self.ctx?.wv !== wv, same(model, wv),
                      let app = model.appModel else { return }
                let sources = legacySources(app)
                if onlyIfLegacyLeft, sources.isEmpty { return }
                self.promoteSources(sources, model: model, wv: wv, key: key, host: host, page: page, gen: gen, session: session) { [weak self, weak model, weak wv] in
                    guard let self = self, let model = model, let wv = wv, self.ctx?.wv !== wv, same(model, wv),
                          let app = model.appModel else { return }
                    self.applyRules(wv: wv, app: app, key: key, host: host, page: page) { [weak model] skipped in
                        if skipped > 0, let model = model, model.notice == nil {
                            model.notice = "같은 사이트 숨김 규칙 \(skipped)개는 이 페이지의 구조가 달라 적용하지 않았습니다."
                        }
                    }
                }
            }
        }
        pass(after: 2_000_000_000, onlyIfLegacyLeft: false)
        pass(after: 7_000_000_000, onlyIfLegacyLeft: true)
    }
}

private enum AdHideScript {
    static func make(_ op: String, page: String, sels: [String], viewW: CGFloat, rect: NSRect? = nil,
                     site: [AdHideSiteEntry] = []) -> String {
        var args: [String: Any] = ["op": op, "page": page, "sels": sels, "viewW": Double(viewW),
                                   "site": site.map { e -> [String: Any] in
                                       var d: [String: Any] = ["s": e.selector, "fp": e.fp]
                                       if let id = e.ident { d["id"] = id; d["up"] = e.up ?? 0 }
                                       if let sl = e.slot {
                                           var sd: [String: Any] = ["a": sl.a, "n": sl.n,
                                                                    "p": sl.p.map { ["t": $0.t, "c": $0.c, "i": $0.i] as [String: Any] }]
                                           if let k = sl.k { sd["k"] = k }
                                           if let an = sl.an { sd["an"] = an }
                                           if let w = sl.w { sd["w"] = w }
                                           if let t = sl.t { sd["t"] = t }
                                           d["slot"] = sd
                                       }
                                       return d
                                   }]
        if let r = rect { args["rect"] = ["x": Double(r.minX), "y": Double(r.minY), "w": Double(r.width), "h": Double(r.height)] }
        guard JSONSerialization.isValidJSONObject(args),
              let data = try? JSONSerialization.data(withJSONObject: args),
              let json = String(data: data, encoding: .utf8) else { return "null" }
        return "(function(args){" + body + "})(" + json + ")"
    }

    private static let body = #"""
    try {
      if (location.href.split('#')[0] !== args.page) return null;
      var W = window.innerWidth || document.documentElement.clientWidth || 0;
      var H = window.innerHeight || document.documentElement.clientHeight || 0;
      if (!(W > 0 && H > 0)) return null;
      function q(s) { try { return document.querySelectorAll(s); } catch (e) { return []; } }
      function unique(s) { var n = q(s); return n.length === 1 ? n[0] : null; }
      function removeStyleNode() {
        var o = window.__htdAdHideStyle; window.__htdAdHideStyle = null; if (o && o.parentNode) o.parentNode.removeChild(o);
        var m = window.__htdAdHideMarks; window.__htdAdHideMarks = null;
        for (var i = 0; m && i < m.length; i++) { try { m[i].removeAttribute('data-htd-adhide'); } catch (e) {} }
      }
      function stopWatch() {
        var w = window.__htdAdHideWatch; window.__htdAdHideWatch = null;
        if (w) { try { w.o.disconnect(); } catch (e) {} if (w.t) clearTimeout(w.t); }
      }
      function removeStyle() { stopWatch(); removeStyleNode(); }
      function structural(el) {
        var t = el.tagName;
        if (t === 'HTML' || t === 'BODY' || t === 'HEAD' || t === 'MAIN') return true;
        var r = el.getBoundingClientRect();
        return r.width * r.height > 0.5 * W * H || (r.width >= 0.9 * W && r.height >= 0.6 * H);
      }
      // Same-host guard: a rule that follows the user to other pages must never be able to swallow a page's main content.
      function textBucket(el) {
        var n = 0, w = document.createTreeWalker(el, NodeFilter.SHOW_TEXT, null), t;
        while ((t = w.nextNode()) && n < 1000) {
          var p = t.parentNode && t.parentNode.nodeName;
          if (p === 'SCRIPT' || p === 'STYLE' || p === 'NOSCRIPT' || p === 'TEMPLATE') continue;
          n += t.nodeValue.replace(/\s+/g, ' ').trim().length;
        }
        return n === 0 ? 0 : n < 40 ? 1 : n < 200 ? 2 : n < 1000 ? 3 : 4;
      }
      function flagsOf(el) {
        return (el.querySelector('iframe') || el.tagName === 'IFRAME' ? 1 : 0) | (el.querySelector('ins') || el.tagName === 'INS' ? 2 : 0)
          | (el.querySelector('video,audio') ? 4 : 0) | (el.querySelector('form,input,textarea,select,button') ? 8 : 0);
      }
      function fpOf(el) {
        var chain = [], c = el;
        for (var i = 0; i < 4 && c && c.nodeType === 1 && c !== document.documentElement; i++) { chain.push(c.tagName.toLowerCase()); c = c.parentElement; }
        return chain.join(',') + '|' + textBucket(el) + '|' + flagsOf(el);
      }
      function domainOK(el) {
        if (structural(el)) return false;
        var r = el.getBoundingClientRect();
        if (r.width * r.height > 0.3 * W * H || (r.width >= 0.9 * W && r.height >= 0.4 * H)) return false;
        if (/^(ARTICLE|MAIN|HEADER|FOOTER|NAV|FORM|SECTION)$/.test(el.tagName) || el.getAttribute('role') === 'main') return false;
        if (el.querySelector('article,main,h1,[role="main"]')) return false;
        return textBucket(el) < 4;
      }
      function sameFp(el, fp) {
        var a = String(fp).split('|'), b = fpOf(el).split('|');
        return a.length === 3 && a[0] === b[0] && (parseInt(a[2], 10) & 15) === (parseInt(b[2], 10) & 15) && parseInt(b[1], 10) <= parseInt(a[1], 10);
      }
      // Classic anchored rule whose creative changed in place (IFRAME -> IMG/text/ins): same tag/parent chain and the same
      // form flag, and nothing article/heading-like inside. Content-independent on purpose (flags/text bucket may change);
      // `domainOK` has already bounded the element's size, main-like content and text. Only used next to `sameFp`.
      function sameCoarse(el, fp) {
        var a = String(fp).split('|'), b = fpOf(el).split('|');
        if (a.length !== 3 || a[0] !== b[0] || ((parseInt(a[2], 10) ^ parseInt(b[2], 10)) & 8)) return false;
        return !el.querySelector('article,main,h1,h2,h3,h4,h5,h6,[role="main"],[role="heading"]');
      }
      // Provider identity for regions without an own anchor (ancestor-anchored iframe, positional footer slot): the ad
      // iframe's host+path only (never its query/ids). A rule hides an element only if it really holds such an iframe,
      // is not page-sized, holds no article/main/h1 and little text, so a generic chain can never swallow page content.
      function sigOf(f) {
        try {
          var u = new URL(f.getAttribute('src') || '', location.href);
          if (u.protocol !== 'https:' && u.protocol !== 'http:') return '';
          var g = (u.hostname + u.pathname).toLowerCase();
          return /^[a-z0-9._\/-]{5,100}$/.test(g) && u.hostname.indexOf('.') > 0 ? g : '';
        } catch (e) { return ''; }
      }
      function framesIn(el) { return el.tagName === 'IFRAME' ? [el] : Array.prototype.slice.call(el.querySelectorAll('iframe'), 0, 12); }
      function sigDepth(el, sg) {
        var fs = framesIn(el), best = -1;
        for (var i = 0; i < fs.length; i++) {
          if (sigOf(fs[i]) !== sg) continue;
          var c = fs[i], k = 0;
          while (c && c !== el && k <= 6) { c = c.parentElement; k++; }
          if (c === el && (best < 0 || k < best)) best = k;
        }
        return best;
      }
      function hasSig(el, sg, maxUp) { var d = sigDepth(el, sg); return d >= 0 && d <= maxUp; }
      function textLen(el) {
        var n = 0, w = document.createTreeWalker(el, NodeFilter.SHOW_TEXT, null), t;
        while ((t = w.nextNode()) && n < 4000) {
          var p = t.parentNode && t.parentNode.nodeName;
          if (p === 'SCRIPT' || p === 'STYLE' || p === 'NOSCRIPT' || p === 'TEMPLATE') continue;
          n += t.nodeValue.replace(/\s+/g, ' ').trim().length;
        }
        return n;
      }
      // An ad-only subtree: no text at all, a handful of nodes, only a few iframes and nothing that can be page content
      // (no headings/article/main/forms/media/links/images). Its size is then irrelevant, so a short viewport cannot make
      // a 815x333 ad slot look "page-sized". Any text, link or heading keeps the normal size guard.
      function adOnly(el) {
        var t = el.tagName;
        if (t === 'HTML' || t === 'BODY' || t === 'HEAD' || t === 'MAIN') return false;
        if (textLen(el) !== 0) return false;
        if (el.querySelectorAll('*').length > 40) return false;
        if (el.querySelector('article,main,h1,h2,h3,h4,h5,h6,form,input,textarea,select,button,video,audio,a,img,p,li,table,[role="main"]')) return false;
        return framesIn(el).length >= 1 && el.querySelectorAll('iframe').length <= 3;
      }
      function identGuard(el) {
        if (structural(el) && !adOnly(el)) return false;
        if (/^(ARTICLE|MAIN|HEADER|FOOTER|NAV|FORM|SECTION)$/.test(el.tagName) || el.getAttribute('role') === 'main') return false;
        if (el.querySelector('article,main,h1,[role="main"]')) return false;
        return textLen(el) < 3000;
      }
      function identOf(el) {
        var fs = framesIn(el);
        for (var i = 0; i < fs.length; i++) {
          var sg = sigOf(fs[i]);
          if (!sg) continue;
          var d = sigDepth(el, sg);
          if (d >= 0) return { id: sg, up: d };
        }
        return null;
      }
      // The element a provider-identified rule means: the selector's unique match if it holds the provider iframe, else the
      // single element found by climbing `up` parents from the provider iframes (positions shifted). Null if unsure.
      // The saved fingerprint's text bucket is a ceiling: a zero-text ad slot may not resolve to a parent that gained
      // article text. Without a usable fingerprint only an ad-only subtree qualifies. The tag chain may vary.
      function identFits(el, en) {
        if (!identGuard(el)) return false;
        if (adOnly(el)) return true;
        var a = String(en.fp || '').split('|'), saved = a.length === 3 ? parseInt(a[1], 10) : NaN;
        return !isNaN(saved) && textBucket(el) <= saved;
      }
      // Selector's unique match still holds the provider iframe: { el } (el null if it no longer fits), else null.
      function identAtSelector(en) {
        var el = unique(en.s);
        if (!el || !hasSig(el, en.id, en.up)) return null;
        return { el: identFits(el, en) ? el : null };
      }
      // Provider search over the whole page (last resort, after the selector/slot routes). EVERY candidate, also a single
      // one, must lie on the stored selector's stable ancestor chain (nth-of-type positions dropped), so a legacy rule can
      // never jump to another place that merely uses the same provider.
      function identSearch(en) {
        var fs = q('iframe'), found = [];
        for (var i = 0; i < fs.length && i < 80; i++) {
          if (sigOf(fs[i]) !== en.id) continue;
          var c = fs[i];
          for (var u = 0; u < en.up && c; u++) c = c.parentElement;
          if (c && found.indexOf(c) < 0) found.push(c);
        }
        if (!found.length) return null;
        var sel = String(en.s || '').replace(/:nth-of-type\(\d+\)/g, '');
        if (!/[#.]/.test(sel)) return null;
        var kept = [];
        for (var k = 0; k < found.length; k++) {
          try { if (found[k].matches(sel)) kept.push(found[k]); } catch (e) { return null; }
        }
        if (kept.length !== 1) return null;
        return hasSig(kept[0], en.id, en.up) && identFits(kept[0], en) ? kept[0] : null;
      }
      function stable(s) { return /^[A-Za-z_][A-Za-z0-9_-]{0,39}$/.test(s) && !/[0-9]{3,}/.test(s); }
      function build(el, useNth) {
        var parts = [], cur = el;
        for (var d = 0; d < 8 && cur && cur.nodeType === 1 && cur !== document.documentElement && cur !== document.body; d++) {
          var t = cur.tagName.toLowerCase();
          if (!/^[a-z][a-z0-9-]*$/.test(t)) return null;
          var part, isId = false;
          if (cur.id && stable(cur.id) && q('#' + cur.id).length === 1) { part = '#' + cur.id; isId = true; }
          else {
            var cl = Array.prototype.filter.call(cur.classList || [], stable).slice(0, 2);
            part = t + cl.map(function (c) { return '.' + c; }).join('');
            var p = cur.parentElement;
            if (useNth && p) {
              var same = Array.prototype.filter.call(p.children, function (c) { return c.tagName === cur.tagName; });
              if (same.length > 1) part += ':nth-of-type(' + (same.indexOf(cur) + 1) + ')';
            }
          }
          parts.unshift(part);
          var sel = parts.join(' > ');
          if (sel.length > 300) return null;
          if (unique(sel) === el) return sel;
          if (isId) return null;
          cur = cur.parentElement;
        }
        return null;
      }
      // ---- Stable slot descriptor: the container of an ad, described by a stable ancestor and a relative path, never by
      // what currently sits inside (provider, query, creative, text). A position number alone is NOT an identity: a
      // positional path is trusted only if every branch still has the stored cardinality AND the container still holds a
      // stable layout witness (a wrapper class inside the container, outside the creative). Ambiguous -> null -> visible.
      var GENERIC = { container: 1, content: 1, contents: 1, wrapper: 1, wrap: 1, main: 1, body: 1, article: 1, post: 1, view: 1, inner: 1,
        row: 1, col: 1, layout: 1, page: 1, box: 1, list: 1, item: 1, text: 1, title: 1, section: 1, area: 1, document: 1, entry: 1 };
      var STATE_CLS = /^(active|open|opened|closed|show|shown|on|off|hide|hidden|visible|loaded|loading|current|selected|first|last|odd|even|clearfix|cf|fixed|sticky|scrolled|collapsed|expanded|ready)$/i;
      var LAYOUT_CLS = /^(left|right|center|clear|padding|margin|block|table|cell|outer|fl|fr|float|pull|push)$/i;
      var WIT_SKIP = /^(IFRAME|INS|IMG|A|SCRIPT|STYLE|NOSCRIPT|SVG|VIDEO|AUDIO|CANVAS|SOURCE|BR|OBJECT|EMBED)$/;
      function slotClasses(el) {
        var out = [], cl = el.classList;
        for (var i = 0; cl && i < cl.length && out.length < 2; i++) if (stable(cl[i]) && !STATE_CLS.test(cl[i])) out.push(cl[i]);
        return out;
      }
      function sameKind(el, t, c) {
        if (el.tagName.toLowerCase() !== t) return false;
        for (var i = 0; i < c.length; i++) if (!el.classList.contains(c[i])) return false;
        return true;
      }
      // i: 0 = the only element of its kind (tag + stable classes) among its siblings, else its 1-based position among them;
      // k: how many of that kind there are. null when the parent is too large to count reliably.
      function kindInfo(el) {
        var p = el.parentElement;
        if (!p) return { i: 0, k: 1 };
        if (p.children.length > 400) return null;
        var t = el.tagName.toLowerCase(), c = slotClasses(el), n = 0, at = 0;
        for (var i = 0; i < p.children.length; i++) {
          if (sameKind(p.children[i], t, c)) { n++; if (p.children[i] === el) at = n; }
        }
        return { i: n > 1 ? at : 0, k: n };
      }
      // May this element stand for an ad slot at all? Never page content: no article/main/headings/forms/navigation, no
      // link list, little text, not page-sized (unless it is an ad-only subtree), not a structural tag.
      function slotGuard(el) {
        var t = el.tagName;
        if (t === 'HTML' || t === 'BODY' || t === 'HEAD') return false;
        if (/^(ARTICLE|MAIN|HEADER|FOOTER|NAV|FORM|SECTION|P|H1|H2|H3|H4|H5|H6)$/.test(t) || el.getAttribute('role') === 'main') return false;
        if (el.querySelector('article,main,h1,h2,h3,h4,h5,h6,nav,[role="main"],[role="article"],form,input,textarea,select')) return false;
        if (textLen(el) >= 300 || el.querySelectorAll('*').length > 80) return false;
        var as = el.querySelectorAll('a'), linked = 0;
        for (var li = 0; li < as.length && li < 20; li++) if (textLen(as[li]) > 0 && ++linked >= 3) return false;
        return !structural(el) || adOnly(el);
      }
      // An iframe/ins/image/link that is the only content of its wrapper (script/style/noscript/br beside it do not count) is
      // represented by the wrapper: the creative element may be swapped, the wrapper (the slot) stays.
      function shellParent(el) {
        var t = el.tagName;
        if (t !== 'IFRAME' && t !== 'INS' && t !== 'IMG' && t !== 'A') return null;
        var p = el.parentElement;
        if (!p || p === document.body || p === document.documentElement || p.children.length > 6 || textLen(p) !== 0) return null;
        for (var i = 0; i < p.children.length; i++) {
          if (!/^(IFRAME|INS|IMG|A|SCRIPT|STYLE|NOSCRIPT|BR)$/.test(p.children[i].tagName)) return null;
        }
        return slotGuard(p) ? p : null;
      }
      function anchorSel(p) {
        if (p.id && stable(p.id) && p.id.length >= 3 && !GENERIC[p.id.toLowerCase()]) {
          var s = '#' + p.id;
          if (unique(s) === p) return { s: s, n: 0, r: 0, cnt: 1 };
        }
        var cl = slotClasses(p).filter(function (c) { return c.length >= 3 && !GENERIC[c.toLowerCase()]; });
        if (!cl.length) return null;
        var s2 = p.tagName.toLowerCase() + cl.map(function (c) { return '.' + c; }).join('');
        if (!/^[a-z][a-z0-9-]*(\.[A-Za-z_][A-Za-z0-9_-]*)+$/.test(s2)) return null;
        var all = q(s2);
        if (all.length < 1 || all.length > 12) return null;
        var at = Array.prototype.indexOf.call(all, p);
        if (at < 0) return null;
        return { s: s2, n: all.length === 1 ? 0 : at + 1, r: all.length === 1 ? 0 : 1, cnt: all.length };
      }
      // Layout witness of a container: up to 3 `tag.class` tokens of classed wrappers inside it (depth <= 3), skipping the
      // creative itself (iframe/ins/img/link/media) and generic layout words. Independent of provider, query and ad text.
      function witnessOf(leaf) {
        var out = [], queue = [], depth = [], seen = 0, qi = 0, i;
        for (i = 0; i < leaf.children.length && i < 40; i++) { queue.push(leaf.children[i]); depth.push(1); }
        while (qi < queue.length && seen < 60 && out.length < 3) {
          var e = queue[qi], dp = depth[qi]; qi++; seen++;
          if (WIT_SKIP.test(e.tagName)) continue;
          var cl = slotClasses(e).filter(function (c) { return c.length >= 3 && !GENERIC[c.toLowerCase()] && !LAYOUT_CLS.test(c); });
          if (cl.length) {
            var tok = e.tagName.toLowerCase() + '.' + cl[0];
            if (/^[a-z][a-z0-9-]{0,19}\.[A-Za-z_][A-Za-z0-9_-]{0,39}$/.test(tok) && out.indexOf(tok) < 0) out.push(tok);
          }
          if (dp < 3) for (i = 0; i < e.children.length && i < 40 && queue.length < 200; i++) { queue.push(e.children[i]); depth.push(dp + 1); }
        }
        return out;
      }
      function witnessOK(el, w) {
        if (!w || !w.length) return false;
        for (var i = 0; i < w.length && i < 3; i++) {
          try { if (el.querySelector(w[i])) return true; } catch (e) {}
        }
        return false;
      }
      // Stored text bucket of a positional slot is a ceiling (+1 step, never 200+ chars): changed creatives may carry a
      // little text, a text block may not take the slot's place.
      function textOK(el, slot) { return slot.t == null || textBucket(el) <= Math.min(slot.t + 1, 2); }
      function slotOrdinal(slot) {
        if (slot.n > 0) return true;
        for (var i = 0; i < slot.p.length; i++) if (slot.p[i].i > 0) return true;
        return false;
      }
      function slotAnchors(slot) {
        var all = q(slot.a), out = [];
        for (var i = 0; i < all.length && i < 13; i++) out.push(all[i]);
        return out;
      }
      // ks: stored cardinalities, required (and compared) wherever a step is positional.
      // creative: the path is fully non-positional (unique anchor, only-of-its-kind steps), so a last step that is a plain
      // classless iframe/ins/img whose exact tag is gone may be taken by the ONE direct iframe/ins/img child at that path.
      function walkStrict(anchor, steps, ks, creative) {
        var cur = anchor;
        for (var k = 0; k < steps.length; k++) {
          var st = steps[k], kids = [];
          if (cur.children.length > 400) return null;
          for (var i = 0; i < cur.children.length; i++) if (sameKind(cur.children[i], st.t, st.c || [])) kids.push(cur.children[i]);
          if (st.i === 0) {
            if (kids.length === 0 && creative && k === steps.length - 1 && !(st.c && st.c.length) && /^(iframe|ins|img)$/.test(st.t)) {
              for (var ci = 0; ci < cur.children.length; ci++) if (/^(IFRAME|INS|IMG)$/.test(cur.children[ci].tagName)) kids.push(cur.children[ci]);
            }
            if (kids.length !== 1) return null;
            cur = kids[0];
          }
          else { if (!ks || kids.length !== ks[k] || st.i > kids.length) return null; cur = kids[st.i - 1]; }
        }
        return cur;
      }
      function walkLoose(anchor, steps) {
        var layer = [anchor];
        for (var k = 0; k < steps.length; k++) {
          var next = [];
          for (var a = 0; a < layer.length; a++) {
            if (layer[a].children.length > 400) return [];
            for (var i = 0; i < layer[a].children.length; i++) {
              if (sameKind(layer[a].children[i], steps[k].t, steps[k].c || [])) next.push(layer[a].children[i]);
              if (next.length > 60) return [];
            }
          }
          layer = next;
          if (!layer.length) return [];
        }
        return layer;
      }
      // Exact path from the stable anchor. A non-positional path (unique anchor, only-child-of-its-kind steps) is the
      // identity. A positional path (anchor ordinal or step ordinal) needs stored branch metadata whose cardinalities still
      // hold, and the container must still hold a layout witness and stay within the stored text ceiling; otherwise null.
      function resolveSlotStrict(slot) {
        var anchors = slotAnchors(slot), ord = slotOrdinal(slot), meta = Array.isArray(slot.k) && slot.k.length === slot.p.length, a;
        if (ord && !(meta && Array.isArray(slot.w) && slot.w.length)) return null;
        if (slot.n === 0) { if (anchors.length !== 1) return null; a = anchors[0]; }
        else { if (!meta || slot.an !== anchors.length || slot.n > anchors.length) return null; a = anchors[slot.n - 1]; }
        var leaf = walkStrict(a, slot.p, meta ? slot.k : null, !ord);
        if (!leaf) return null;
        if (ord && !(witnessOK(leaf, slot.w) && textOK(leaf, slot))) return null;
        return leaf;
      }
      // A loose (position-free) candidate is acceptable only with positive evidence: the stored witness inside it, or - for
      // a non-positional slot without witness - the slot's own stable class on the container itself. Anonymous or purely
      // positional containers are never accepted this way.
      function looseOK(lf, slot) {
        if (Array.isArray(slot.w) && slot.w.length) { if (!witnessOK(lf, slot.w)) return false; }
        else {
          var last = slot.p[slot.p.length - 1];
          if (slotOrdinal(slot) || !(last.c && last.c.length)) return false;
        }
        return textOK(lf, slot);
      }
      // Layout shifted (positions or counts changed): same anchor(s) and same tag/class path, accepted only if exactly ONE
      // short-text container qualifies with looseOK; two or more is ambiguous and nothing is hidden.
      function resolveSlotLoose(slot, claimed) {
        var anchors = slotAnchors(slot), found = [];
        if (anchors.length > 12) return { el: null, amb: true };
        for (var i = 0; i < anchors.length; i++) {
          var leaves = walkLoose(anchors[i], slot.p);
          for (var k = 0; k < leaves.length; k++) {
            var lf = leaves[k];
            if (claimed.indexOf(lf) < 0 && found.indexOf(lf) < 0 && slotGuard(lf) && textLen(lf) < 40 && looseOK(lf, slot)) found.push(lf);
          }
        }
        return { el: found.length === 1 ? found[0] : null, amb: found.length > 1 };
      }
      // Descriptor of the slot an element belongs to: nearest stable anchor outside it (unique id preferred, then a unique
      // class, then a class with a few matches), with branch cardinalities. A positional result needs a layout witness
      // (else null: such a slot could not be told apart from unrelated siblings). Checked by resolving it back to the leaf.
      function slotOf(el) {
        var leaf = shellParent(el) || el;
        if (!slotGuard(leaf)) return null;
        var steps = [], ks = [], cur = leaf, best = null;
        for (var d = 0; d < 6 && cur && cur.parentElement; d++) {
          if (cur === document.body || cur === document.documentElement) break;
          var ki = kindInfo(cur);
          if (!ki) return null;
          steps.unshift({ t: cur.tagName.toLowerCase(), c: slotClasses(cur), i: ki.i });
          ks.unshift(ki.k);
          var p = cur.parentElement;
          if (p === document.body || p === document.documentElement) break;
          var a = anchorSel(p);
          if (a) {
            var pos = !!a.r;
            for (var si2 = 0; si2 < steps.length; si2++) if (steps[si2].i > 0) pos = true;
            var score = (pos ? 20 : 0) + (a.s.charAt(0) === '#' ? 0 : 2) + d;
            if (!best || score < best.score) best = { a: a, steps: steps.slice(), ks: ks.slice(), score: score };
            if (!a.r && a.s.charAt(0) === '#') break;
          }
          cur = p;
        }
        if (!best) return null;
        var slot = { a: best.a.s, n: best.a.n, p: best.steps, k: best.ks };
        if (best.a.n > 0) slot.an = best.a.cnt;
        var w = witnessOf(leaf);
        if (slotOrdinal(slot)) {
          if (!w.length) return null;
          slot.t = textBucket(leaf);
        }
        if (w.length) slot.w = w;
        return resolveSlotStrict(slot) === leaf ? slot : null;
      }
      function strictSlot(slot, claimed) {
        var r = resolveSlotStrict(slot);
        return r && slotGuard(r) && claimed.indexOf(r) < 0 ? r : null;
      }
      // A provider-identified rule without validated slot whose provider is gone: the stored selector's unique current match
      // may stand for the slot if slotOf() finds a SAFE one for it (unique non-positional anchor/path, or an ordinal path with
      // a layout witness - slotOf refuses ordinal slots without one), it is still ad-like (holds/is iframe/ins/img), and
      // its text stays within the saved fingerprint ceiling. Returns { el, slot } (slot is stored by Swift) or null.
      function migrateFromSelector(en, sn, claimed) {
        if (!sn) return null;
        var ms = slotOf(sn);
        if (!ms) return null;
        if (slotOrdinal(ms) && !(Array.isArray(ms.w) && ms.w.length)) return null;
        var leaf = resolveSlotStrict(ms);
        if (!leaf || !slotGuard(leaf) || claimed.indexOf(leaf) >= 0) return null;
        if (!/^(IFRAME|INS|IMG)$/.test(leaf.tagName) && !leaf.querySelector('iframe,ins,img')) return null;
        var a = String(en.fp || '').split('|'), saved = a.length === 3 ? parseInt(a[1], 10) : NaN;
        if (!isNaN(saved) && textBucket(leaf) > saved) return null;
        return { el: leaf, slot: ms };
      }
      // All host rules of this page -> [{el, sel, via}] by rule index (null: not resolved). Exact matches first (provider
      // identity as in 1.7.0, then the slot path, then the classic selector), then layout-shifted slots among the elements
      // nobody else claimed.
      function resolveSite(site, editing) {
        var res = [], claimed = [], skip = 0, si, en, re, via;
        for (si = 0; si < site.length && si < 30; si++) {
          en = site[si]; re = null; via = '';
          var sn = unique(en.s), mslot = null;
          if (en.slot && Array.isArray(en.slot.k)) {
            // Validated slot (with branch metadata): re-resolved first and on its own. If it is ambiguous or no longer valid
            // it is NOT overridden by a provider search elsewhere (loose pass below, else nothing is hidden).
            re = strictSlot(en.slot, claimed);
            if (re) via = 's';
          } else {
            var ia = en.id ? identAtSelector(en) : null;
            if (ia) { re = ia.el; if (re) via = 'i'; }
            if (!re && en.slot) { re = strictSlot(en.slot, claimed); if (re) via = 's'; }
            if (!re && en.id && !ia) {
              // Provider changed/gone: derive the slot from the selector's CURRENT match before any provider search.
              var mg = migrateFromSelector(en, sn, claimed);
              if (mg) { re = mg.el; mslot = mg.slot; via = 'm'; }
              else { re = identSearch(en); if (re && claimed.indexOf(re) >= 0) re = null; if (re) via = 'i'; }
            }
          }
          if (re) { res[si] = { el: re, sel: re === sn ? en.s : null, via: via, slot: mslot }; claimed.push(re); continue; }
          if (!en.id && !en.slot && sn) {
            if (editing || (domainOK(sn) && (sameFp(sn, en.fp) || sameCoarse(sn, en.fp)))) { res[si] = { el: sn, sel: en.s, via: 'c' }; claimed.push(sn); }
            else skip++;
          }
        }
        for (si = 0; si < site.length && si < 30; si++) {
          en = site[si];
          if (res[si]) continue;
          if (en.slot) {
            var lr = resolveSlotLoose(en.slot, claimed);
            if (lr.el) { res[si] = { el: lr.el, sel: null, via: 'l' }; claimed.push(lr.el); continue; }
            if (lr.amb) { skip++; continue; }
          }
          var sn2 = en.id ? unique(en.s) : null;
          if (sn2 && hasSig(sn2, en.id, en.up)) skip++;
        }
        return { res: res, skip: skip };
      }
      function markFallback(el) {
        el.setAttribute('data-htd-adhide', '1');
        var m = window.__htdAdHideMarks || (window.__htdAdHideMarks = []);
        if (m.indexOf(el) < 0 && m.length < 60) m.push(el);
        return '[data-htd-adhide="1"]';
      }
      // Hides this page's rules plus the host's rules (classic: guard + fingerprint; provider-identified: iframe identity;
      // slot: stable container). Provider-identified rules that resolved by their provider and have no slot with branch metadata
      // report one derived from the live element (`mig`) to be stored.
      function runApply(a) {
        removeStyleNode();
        var ok = [];
        for (var i = 0; i < a.sels.length && i < 30; i++) {
          var n = unique(a.sels[i]);
          if (n && !structural(n)) ok.push(a.sels[i]);
        }
        var site = a.site || [], rsv = resolveSite(site, false), skip = rsv.skip, mig = [];
        for (var si = 0; si < site.length && si < 30; si++) {
          var rr = rsv.res[si];
          if (!rr) continue;
          var rs = rr.sel;
          if (!rs) { rs = build(rr.el, false) || build(rr.el, true); if (!rs || unique(rs) !== rr.el) rs = markFallback(rr.el); }
          ok.push(rs);
          if (site[si].id && (rr.via === 'i' || rr.via === 'm') && !(site[si].slot && site[si].slot.k) && mig.length < 8) {
            var ms = rr.slot || slotOf(rr.el);
            if (ms) mig.push({ i: si, slot: ms });
          }
        }
        if (ok.length) {
          var st = document.createElement('style');
          st.textContent = ok.map(function (s) { return s + '{display:none !important}'; }).join('\n');
          (document.head || document.documentElement).appendChild(st);
          window.__htdAdHideStyle = st;
        }
        return { n: ok.length, skip: skip, mig: mig };
      }
      // Ad iframes and their containers are often built after load: re-run (debounced, slower the more it ran) on DOM / iframe-src
      // changes for a bounded time and count, only on this exact page; no timer loop, a run needs a DOM change.
      // Its own style change is discarded; nothing is stored.
      function watch(a) {
        if (typeof MutationObserver !== 'function' || !document.documentElement) return;
        var w = { t: 0, runs: 0, until: Date.now() + 90000, o: null };
        w.o = new MutationObserver(function () {
          if (window.__htdAdHideWatch !== w) return;
          if (Date.now() > w.until || w.runs >= 50 || location.href.split('#')[0] !== a.page) { stopWatch(); return; }
          if (w.t) return;
          w.t = setTimeout(function () {
            w.t = 0;
            if (window.__htdAdHideWatch !== w) return;
            if (Date.now() > w.until || w.runs >= 50 || location.href.split('#')[0] !== a.page) { stopWatch(); return; }
            w.runs++;
            try { runApply(a); } catch (e) {}
            w.o.takeRecords();
          }, w.runs < 10 ? 150 : w.runs < 30 ? 600 : 2000);
        });
        w.o.observe(document.documentElement, { childList: true, subtree: true, attributes: true, attributeFilter: ['src'] });
        window.__htdAdHideWatch = w;
      }
      if (args.op === 'apply') {
        stopWatch();
        var res = runApply(args);
        if ((args.sels && args.sels.length) || (args.site && args.site.length)) watch(args);
        return res;
      }
      if (args.op === 'promote') {
        removeStyle();
        var pr = [];
        for (var pi = 0; pi < args.sels.length && pi < 30; pi++) {
          var pn = unique(args.sels[pi]);
          if (!pn) continue;
          var item = { s: args.sels[pi], fp: fpOf(pn), dom: domainOK(pn) };
          var pid = identOf(pn);
          if (pid && identGuard(pn)) { item.id = pid.id; item.up = pid.up; item.idDom = true; }
          var psl = slotOf(pn);
          if (psl) item.slot = psl;
          if (item.dom || item.idDom || item.slot) pr.push(item);
        }
        return pr;
      }
      if (args.op === 'enter') {
        removeStyle();
        var k = args.viewW / W, out = [], en2 = args.site || [], rsite = resolveSite(en2, true);
        // Index j: this page's rules first, then the host's rules (same order as the Swift side lists them).
        for (var j = 0; j < args.sels.length + en2.length && j < 60; j++) {
          var rr2 = j < args.sels.length ? null : rsite.res[j - args.sels.length];
          var e = j < args.sels.length ? unique(args.sels[j]) : (rr2 ? rr2.el : null);
          if (!e || e === document.documentElement || e === document.body) continue;
          var r = e.getBoundingClientRect();
          var x0 = Math.max(0, r.left), y0 = Math.max(0, r.top), x1 = Math.min(W, r.right), y1 = Math.min(H, r.bottom);
          if (x1 - x0 >= 2 && y1 - y0 >= 2) out.push({ i: j, x: x0 * k, y: y0 * k, w: (x1 - x0) * k, h: (y1 - y0) * k });
        }
        return out;
      }
      if (args.op === 'add') {
        removeStyle();
        var k2 = W / args.viewW, a = args.rect;
        var L = a.x * k2, T = a.y * k2, R = L + a.w * k2, B = T + a.h * k2, SA = (R - L) * (B - T);
        if (!(SA > 0)) return { err: 'none' };
        var seen = [], best = null, bestScore = 0, bestArea = 0;
        for (var u = 0; u < 5; u++) for (var v = 0; v < 5; v++) {
          var st2 = document.elementsFromPoint(L + (R - L) * (u + 0.5) / 5, T + (B - T) * (v + 0.5) / 5);
          for (var m = 0; m < st2.length && m < 12; m++) {
            var el = st2[m];
            if (seen.indexOf(el) >= 0) continue;
            seen.push(el);
            if (structural(el)) continue;
            var rr = el.getBoundingClientRect();
            var iw = Math.min(R, rr.right) - Math.max(L, rr.left), ih = Math.min(B, rr.bottom) - Math.max(T, rr.top);
            if (iw <= 0 || ih <= 0) continue;
            var area = rr.width * rr.height, inter = iw * ih, score = inter / (SA + area - inter);
            if (score > bestScore || (score === bestScore && best && area < bestArea)) { best = el; bestScore = score; bestArea = area; }
          }
        }
        if (!best || bestScore < 0.35) return { err: 'none' };
        var sel = build(best, false) || build(best, true);
        if (!sel || unique(sel) !== best) return { err: 'sel' };
        if (args.sels.indexOf(sel) >= 0) return { err: 'dup' };
        var idn = identOf(best);
        return { sel: sel, fp: fpOf(best), dom: domainOK(best), id: idn ? idn.id : null, up: idn ? idn.up : 0, idDom: !!(idn && identGuard(best)), slot: slotOf(best) };
      }
      return null;
    } catch (err) { return null; }
    """#
}
