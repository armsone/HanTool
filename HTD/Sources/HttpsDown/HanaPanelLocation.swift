import Foundation
import WebKit
import AppKit
import CoreLocation

/// Retained message handler for native one-shot geolocation bridge (`hloc`) in Hana webview.
/// Contract:
/// - Action: `window.webkit.messageHandlers.hloc.postMessage({action:'once'})`
/// - Reply on success: `{ok: true, latitude: Double, longitude: Double}`
/// - Reply on error: `{ok: false, code: Int}` (1: denied, 2: unavailable, 3: timeout)
@MainActor
final class HanaLocationScriptMessageHandler: NSObject, WKScriptMessageHandlerWithReply {
    private weak var host: HanaPanelHost?
    private let locator = OneShotLocation()
    private var isBusy = false
    private var requestGeneration = 0

    init(host: HanaPanelHost) {
        self.host = host
        super.init()
    }

    func cancelPending() {
        locator.cancel()
        requestGeneration &+= 1
        isBusy = false
    }

    nonisolated func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping (Any?, String?) -> Void
    ) {
        Task { @MainActor in
            self.handleMessage(message, replyHandler: replyHandler)
        }
    }

    private func handleMessage(
        _ message: WKScriptMessage,
        replyHandler: @escaping (Any?, String?) -> Void
    ) {
        var didReply = false
        func replyOnce(_ dict: [String: Any]) {
            guard !didReply else { return }
            didReply = true
            replyHandler(dict, nil)
        }

        // Validate message payload: dictionary with {action: 'once'}
        guard let dict = message.body as? [String: Any],
              let action = dict["action"] as? String,
              action == "once" else {
            replyOnce(["ok": false, "code": 2])
            return
        }

        // Validate host existence
        guard let host = self.host else {
            replyOnce(["ok": false, "code": 2])
            return
        }

        // Validate top mainframe, frameURL, and current webview URL match exact trusted Alfred URL
        guard message.frameInfo.isMainFrame,
              let frameURL = message.frameInfo.request.url,
              HanaPanelHost.isTrustedAlfredURL(frameURL),
              HanaPanelHost.isTrustedAlfredURL(message.webView?.url) else {
            replyOnce(["ok": false, "code": 1])
            return
        }

        // Host panel must be open, webView.window visible, and NSApp active before read
        guard host.isPanelOpen,
              let webView = message.webView,
              let window = webView.window,
              window.isVisible,
              NSApp.isActive else {
            replyOnce(["ok": false, "code": 2])
            return
        }

        // Concurrency check: one outstanding request only, concurrent fail with code 2
        guard !isBusy else {
            replyOnce(["ok": false, "code": 2])
            return
        }

        isBusy = true
        requestGeneration &+= 1
        let currentGen = requestGeneration

        Task { [weak self] in
            guard let self = self else {
                replyOnce(["ok": false, "code": 2])
                return
            }

            let result = await self.locator.fetch(timeout: 45)

            // Re-validate generation: if cancelled or new request started, do not return stale result
            guard self.requestGeneration == currentGen else {
                replyOnce(["ok": false, "code": 1])
                return
            }
            self.isBusy = false

            // Re-validate host, panel, webView, window visibility, and app active status before reply
            guard let host = self.host,
                  host.isPanelOpen,
                  let webView = message.webView,
                  let window = webView.window,
                  window.isVisible,
                  NSApp.isActive,
                  HanaPanelHost.isTrustedAlfredURL(webView.url) else {
                replyOnce(["ok": false, "code": 2])
                return
            }

            switch result {
            case .success(let coord):
                let lat = coord.latitude
                let lon = coord.longitude
                // Validate coordinates are finite and within normal GPS ranges
                guard lat.isFinite, lon.isFinite,
                      lat >= -90.0, lat <= 90.0,
                      lon >= -180.0, lon <= 180.0 else {
                    replyOnce(["ok": false, "code": 2])
                    return
                }
                replyOnce(["ok": true, "latitude": lat, "longitude": lon])

            case .failure(let failure):
                let code: Int
                switch failure {
                case .denied, .cancelled:
                    code = 1
                case .unavailable:
                    code = 2
                case .timedOut:
                    code = 3
                }
                replyOnce(["ok": false, "code": code])
            }
        }
    }
}
