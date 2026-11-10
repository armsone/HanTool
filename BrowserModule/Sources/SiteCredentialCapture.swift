import AppKit
import WebKit

@MainActor
final class SiteCredentialCapture: NSObject, WKScriptMessageHandler {
    private static let handlerName = "siteCredentialCapture"
    private static let scriptIdentifier = "SiteCredentialCaptureScript"
    private static let contentWorldName = "SiteCredentialCaptureWorld"
    private static let contentWorld = WKContentWorld.world(name: contentWorldName)

    private weak var model: LoginBrowserModel?

    init(model: LoginBrowserModel) {
        self.model = model
        super.init()
    }

    static func install(into contentController: WKUserContentController, model: LoginBrowserModel) {
        let handler = SiteCredentialCapture(model: model)
        contentController.add(handler, contentWorld: contentWorld, name: handlerName)

        let scriptSource = """
        (function() {
            if (window.__siteCredentialCaptureInstalled) return;
            window.__siteCredentialCaptureInstalled = true;

            var pickerOfferedForDocument = false;

            function isVisible(el) {
                if (!el) return false;
                var style = window.getComputedStyle(el);
                return style.display !== 'none' && style.visibility !== 'hidden' && style.opacity !== '0' && el.offsetWidth > 0 && el.offsetHeight > 0;
            }

            function isEligibleForm(form, submitter) {
                if (!form) return false;

                const override = (attribute, fallback) =>
                    submitter && submitter.hasAttribute(attribute) ? submitter.getAttribute(attribute) : fallback;
                const method = override('formmethod', form.method).toLowerCase();
                if (method !== 'post') return false;
                const action = override('formaction', form.action);
                try {
                    const destination = new URL(action || location.href, document.baseURI);
                    if (destination.origin !== location.origin || (destination.protocol !== 'https:' && destination.protocol !== 'http:')) return false;
                } catch (_) { return false; }
                const base = document.querySelector('base[target]');
                const target = (override('formtarget', form.getAttribute('target')) || base?.target || '_self').trim();
                if (target.toLowerCase() !== '_self') return false;

                return true;
            }

            function isSignupForm(form) {
                var text = (form.innerText || '') + ' ' + (form.className || '') + ' ' + (form.id || '') + ' ' + (form.getAttribute('action') || '');
                var lower = text.toLowerCase();
                if (lower.indexOf('signup') !== -1 || lower.indexOf('sign-up') !== -1 || lower.indexOf('register') !== -1 || lower.indexOf('create account') !== -1 || lower.indexOf('join') !== -1) {
                    return true;
                }
                return false;
            }

            function extractCredentials(form) {
                if (!form) return null;
                if (isSignupForm(form)) return null;

                // Reject if form has any autocomplete="new-password"
                var allInputs = Array.prototype.slice.call(form.querySelectorAll('input'));
                for (var i = 0; i < allInputs.length; i++) {
                    var ac = (allInputs[i].getAttribute('autocomplete') || '').toLowerCase();
                    if (ac.split(/\\s+/).includes('new-password')) return null;
                }

                // Reject if form contains disabled or readOnly hidden inputs
                var hiddenInputs = Array.prototype.slice.call(form.querySelectorAll('input[type="hidden"]'));
                for (var j = 0; j < hiddenInputs.length; j++) {
                    var h = hiddenInputs[j];
                    if (h.disabled || h.readOnly || h.hasAttribute('disabled') || h.hasAttribute('readonly')) {
                        return null;
                    }
                }

                var pwInputs = Array.prototype.slice.call(form.querySelectorAll('input[type="password"]')).filter(function(input) { return input.form === form && isVisible(input); });
                if (pwInputs.length !== 1) return null;
                var passwordInput = pwInputs[0];
                var password = passwordInput.value;
                if (!password) return null;

                var textInputs = Array.prototype.slice.call(form.querySelectorAll('input[type="text"], input[type="email"], input:not([type])')).filter(function(input) { return input.form === form && isVisible(input); });
                // Exclude search inputs or explicit non-username
                textInputs = textInputs.filter(function(inp) {
                    var t = (inp.getAttribute('type') || '').toLowerCase();
                    return t !== 'search';
                });

                var usernameCandidates = [];
                for (var k = 0; k < textInputs.length; k++) {
                    var inp = textInputs[k];
                    var auto = (inp.getAttribute('autocomplete') || '').toLowerCase();
                    if (auto === 'username' || auto === 'email') {
                        usernameCandidates = [inp];
                        break;
                    }
                    var nameOrId = ((inp.name || '') + ' ' + (inp.id || '')).toLowerCase();
                    if (nameOrId.indexOf('user') !== -1 || nameOrId.indexOf('login') !== -1 || nameOrId.indexOf('email') !== -1 || nameOrId.indexOf('account') !== -1 || nameOrId.indexOf('mb_id') !== -1) {
                        usernameCandidates.push(inp);
                    }
                }
                if (usernameCandidates.length === 0 && textInputs.length === 1) {
                    usernameCandidates.push(textInputs[0]);
                }
                if (usernameCandidates.length !== 1) return null;
                var username = usernameCandidates[0].value.trim();
                if (!username) return null;

                return {
                    username: username,
                    password: password
                };
            }

            document.addEventListener('submit', function(e) {
                if (!e.isTrusted) return;
                if (!navigator.userActivation || !navigator.userActivation.isActive) return;

                var form = e.target;
                if (!form || form.tagName !== 'FORM') return;
                if (window.location.protocol !== 'https:' && window.location.protocol !== 'http:') return;

                var submitter = e.submitter || null;
                if (!isEligibleForm(form, submitter)) return;

                var creds = extractCredentials(form);
                if (!creds) return;

                window.webkit.messageHandlers.siteCredentialCapture.postMessage({
                    type: 'submit',
                    username: creds.username,
                    password: creds.password,
                    href: window.location.href
                });
            }, true);

            function offerFill(e) {
                if (!e.isTrusted) return;
                if (!navigator.userActivation || !navigator.userActivation.isActive) return;
                if (pickerOfferedForDocument) return;

                var target = e.target;
                if (!target || !target.form) return;
                if (!isVisible(target)) return;

                var form = target.form;
                if (window.location.protocol !== 'https:' && window.location.protocol !== 'http:') return;
                if (!isEligibleForm(form, null)) return;
                if (isSignupForm(form)) return;

                // Form must have exactly one visible eligible current password field
                var pwInputs = Array.prototype.slice.call(form.querySelectorAll('input[type="password"]')).filter(function(input) { return input.form === form && isVisible(input); });
                if (pwInputs.length !== 1) return;
                var pwInput = pwInputs[0];
                var pwAuto = (pwInput.getAttribute('autocomplete') || '').toLowerCase();
                if (pwAuto.split(/\\s+/).includes('new-password')) return;

                // Check hidden inputs in form for disabled/readOnly
                var hiddenInputs = Array.prototype.slice.call(form.querySelectorAll('input[type="hidden"]'));
                for (var j = 0; j < hiddenInputs.length; j++) {
                    var h = hiddenInputs[j];
                    if (h.disabled || h.readOnly || h.hasAttribute('disabled') || h.hasAttribute('readonly')) {
                        return;
                    }
                }

                // Target must be a visible actual username or password field
                // Search inputs must not trigger
                var targetType = (target.getAttribute('type') || target.type || '').toLowerCase();
                if (targetType === 'search') return;

                var isTargetPassword = (target === pwInput);
                var isTargetUsername = false;

                if (!isTargetPassword) {
                    var textInputs = Array.prototype.slice.call(form.querySelectorAll('input[type="text"], input[type="email"], input:not([type])')).filter(function(input) { return input.form === form && isVisible(input); });
                    textInputs = textInputs.filter(function(inp) {
                        var t = (inp.getAttribute('type') || '').toLowerCase();
                        return t !== 'search';
                    });

                    var usernameCandidates = [];
                    for (var k = 0; k < textInputs.length; k++) {
                        var inp = textInputs[k];
                        var auto = (inp.getAttribute('autocomplete') || '').toLowerCase();
                        if (auto === 'username' || auto === 'email') {
                            usernameCandidates = [inp];
                            break;
                        }
                        var nameOrId = ((inp.name || '') + ' ' + (inp.id || '')).toLowerCase();
                        if (nameOrId.indexOf('user') !== -1 || nameOrId.indexOf('login') !== -1 || nameOrId.indexOf('email') !== -1 || nameOrId.indexOf('account') !== -1 || nameOrId.indexOf('mb_id') !== -1) {
                            usernameCandidates.push(inp);
                        }
                    }
                    if (usernameCandidates.length === 0 && textInputs.length === 1) {
                        usernameCandidates.push(textInputs[0]);
                    }
                    if (usernameCandidates.length === 1 && usernameCandidates[0] === target) {
                        isTargetUsername = true;
                    }
                }

                if (!isTargetPassword && !isTargetUsername) return;

                pickerOfferedForDocument = true;
                window.webkit.messageHandlers.siteCredentialCapture.postMessage({
                    type: 'focus',
                    href: window.location.href
                });
            }
            document.addEventListener('focusin', offerFill, true);
            document.addEventListener('click', offerFill, true);
        })();
        """

        let script = WKUserScript(
            source: scriptSource,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true,
            in: contentWorld
        )
        contentController.addUserScript(script)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == Self.handlerName else { return }
        guard message.frameInfo.isMainFrame else { return }
        guard let model = model,
              let appModel = model.appModel,
              appModel.selectedTab == .browser,
              appModel.browser === model,
              let webView = model.webView,
              message.webView === webView else { return }

        guard let currentURL = webView.url,
              let scheme = currentURL.scheme?.lowercased(),
              (scheme == "https" || scheme == "http"),
              let popupURL = model.popupCommittedURL,
              popupURL == currentURL else { return }

        guard let body = message.body as? [String: Any],
              let type = body["type"] as? String,
              let href = body["href"] as? String,
              let messageURL = URL(string: href),
              popupURL == messageURL,
              currentURL == messageURL else { return }

        guard let currentOrigin = SiteCredentialStore.canonicalOrigin(for: currentURL),
              let messageOrigin = SiteCredentialStore.canonicalOrigin(for: messageURL),
              currentOrigin == messageOrigin else { return }

        let securityOrigin = message.frameInfo.securityOrigin
        let normalizedSecurityPort = securityOrigin.port == 0 ? (securityOrigin.protocol.lowercased() == "https" ? 443 : (securityOrigin.protocol.lowercased() == "http" ? 80 : 0)) : securityOrigin.port
        let currentPort = currentURL.port ?? (currentURL.scheme?.lowercased() == "https" ? 443 : (currentURL.scheme?.lowercased() == "http" ? 80 : 0))

        guard securityOrigin.host.lowercased() == (currentURL.host?.lowercased() ?? "") else { return }
        guard securityOrigin.protocol.lowercased() == (currentURL.scheme?.lowercased() ?? "") else { return }
        guard normalizedSecurityPort == currentPort else { return }

        if type == "submit" {
            guard let username = body["username"] as? String, !username.isEmpty,
                  let password = body["password"] as? String, !password.isEmpty else { return }
            handleSubmittedCredential(origin: currentOrigin, username: username, password: password, webView: webView)
        } else if type == "focus" {
            handleFocusAutofill(origin: currentOrigin, generation: model.generation, webView: webView)
        }
    }

    private func handleSubmittedCredential(origin: String, username: String, password: String, webView: WKWebView) {
        guard let window = webView.window,
              window.isKeyWindow,
              window.attachedSheet == nil,
              let model = model,
              model.webView === webView else { return }

        let accounts = SiteCredentialStore.accounts(forOrigin: origin)
        let isUpdate = accounts.contains(username)

        if isUpdate {
            guard let existingRecord = SiteCredentialStore.read(origin: origin, username: username) else {
                return
            }
            if existingRecord.password == password {
                return
            }
        }

        let alert = NSAlert()
        var popUpButton: NSPopUpButton?
        let hasExistingAccounts = !isUpdate && !accounts.isEmpty

        if isUpdate {
            alert.messageText = "비밀번호를 업데이트하시겠습니까?"
            alert.informativeText = "\(origin) 사이트의 '\(username)' 계정 저장된 비밀번호를 업데이트하시겠습니까?"
            alert.addButton(withTitle: "업데이트")
            alert.addButton(withTitle: "나중에")
        } else if hasExistingAccounts {
            alert.messageText = "새 계정 저장 또는 기존 계정 대체"
            alert.informativeText = "\(origin) 사이트에 저장된 기존 계정이 있습니다. 새 계정('\(username)')으로 새로 저장하거나, 아래에서 선택한 기존 계정을 대체할 수 있습니다."
            alert.addButton(withTitle: "새로 저장")
            alert.addButton(withTitle: "선택한 계정 대체")
            alert.addButton(withTitle: "취소")

            let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 50))
            let label = NSTextField(labelWithString: "대체할 기존 계정 선택:")
            label.frame = NSRect(x: 0, y: 26, width: 280, height: 18)
            label.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)

            let popUp = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 280, height: 24), pullsDown: false)
            popUp.addItems(withTitles: accounts)
            popUpButton = popUp

            accessory.addSubview(label)
            accessory.addSubview(popUp)
            alert.accessoryView = accessory
        } else {
            alert.messageText = "비밀번호를 저장하시겠습니까?"
            alert.informativeText = "\(origin) 사이트의 '\(username)' 계정 비밀번호를 저장하시겠습니까?"
            alert.addButton(withTitle: "저장")
            alert.addButton(withTitle: "나중에")
        }
        alert.alertStyle = .informational

        alert.beginSheetModal(for: window) { [weak self] response in
            let shouldReplaceExisting = hasExistingAccounts && response == .alertSecondButtonReturn
            guard response == .alertFirstButtonReturn || shouldReplaceExisting else { return }

            let success: Bool
            if isUpdate {
                success = SiteCredentialStore.save(origin: origin, username: username, password: password, replacing: true)
            } else if shouldReplaceExisting {
                guard let chosenOld = popUpButton?.titleOfSelectedItem, !chosenOld.isEmpty else { return }
                success = SiteCredentialStore.replace(origin: origin, oldUsername: chosenOld, username: username, password: password)
            } else {
                success = SiteCredentialStore.save(origin: origin, username: username, password: password, replacing: false)
            }

            if success {
                self?.model?.notice = isUpdate ? "비밀번호를 업데이트했습니다." : "비밀번호를 저장했습니다."
            } else {
                self?.model?.notice = "비밀번호 저장에 실패했습니다."
            }
        }
    }

    private func handleFocusAutofill(origin: String, generation: Int, webView: WKWebView, forcePicker: Bool = false) {
        guard let window = webView.window,
              window.isKeyWindow,
              window.attachedSheet == nil,
              let model = model,
              model.webView === webView else { return }

        let accounts = SiteCredentialStore.accounts(forOrigin: origin)
        guard !accounts.isEmpty else { return }

        let committedURL = model.popupCommittedURL

        let fillAccount = { [weak model, weak webView] (username: String) in
            guard let currentWebView = webView,
                  let currentModel = model else { return }

            SiteAutofill.fill(
                in: currentWebView,
                origin: origin,
                username: username,
                isCurrent: { [weak currentModel, weak currentWebView] in
                    guard let model = currentModel,
                          let wv = currentWebView,
                          let app = model.appModel,
                          app.selectedTab == .browser,
                          app.browser === model,
                          model.webView === wv,
                          let currentWindow = wv.window,
                          currentWindow === window,
                          model.generation == generation,
                          let currentURL = wv.url,
                          let scheme = currentURL.scheme?.lowercased(),
                          (scheme == "https" || scheme == "http"),
                          let targetCommitted = committedURL,
                          model.popupCommittedURL == targetCommitted,
                          currentURL == targetCommitted,
                          let urlOrigin = SiteCredentialStore.canonicalOrigin(for: currentURL),
                          urlOrigin == origin else { return false }
                    return true
                },
                onNotice: { [weak currentModel] message in currentModel?.notice = message }
            )
        }

        if !forcePicker && accounts.count == 1 {
            fillAccount(accounts[0])
            return
        }

        let alert = NSAlert()
        alert.messageText = "로그인 자동 완성"
        alert.informativeText = "\(origin) 사이트에서 채울 계정을 선택하세요:"
        alert.alertStyle = .informational

        final class AccountButtonTarget: NSObject {
            let onSelect: (String) -> Void
            init(onSelect: @escaping (String) -> Void) {
                self.onSelect = onSelect
            }
            @objc func buttonClicked(_ sender: NSButton) {
                onSelect(sender.title)
            }
        }

        weak var sheetWindow: NSWindow?
        let target = AccountButtonTarget { selectedUsername in
            if let sheet = sheetWindow {
                window.endSheet(sheet, returnCode: .cancel)
            }
            fillAccount(selectedUsername)
        }

        let stackView = NSStackView()
        stackView.orientation = .vertical
        stackView.alignment = .leading
        stackView.spacing = 6
        stackView.translatesAutoresizingMaskIntoConstraints = false

        for account in accounts {
            let button = NSButton(title: account, target: target, action: #selector(AccountButtonTarget.buttonClicked(_:)))
            button.bezelStyle = .rounded
            button.setButtonType(.momentaryPushIn)
            button.alignment = .left
            button.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
            button.sizeToFit()
            let buttonWidth = max(260, button.fittingSize.width + 16)
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: buttonWidth).isActive = true
            stackView.addArrangedSubview(button)
        }

        let maxVisibleItems = 5
        let rowHeight: CGFloat = 28
        let totalHeight = CGFloat(accounts.count) * rowHeight
        let scrollViewHeight = min(CGFloat(maxVisibleItems) * rowHeight, totalHeight)

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 280, height: max(scrollViewHeight, 32)))
        scrollView.hasVerticalScroller = accounts.count > maxVisibleItems
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        let clipView = NSClipView()
        clipView.drawsBackground = false
        scrollView.contentView = clipView
        scrollView.documentView = stackView

        stackView.leadingAnchor.constraint(equalTo: clipView.leadingAnchor).isActive = true
        stackView.trailingAnchor.constraint(equalTo: clipView.trailingAnchor).isActive = true
        stackView.topAnchor.constraint(equalTo: clipView.topAnchor).isActive = true

        alert.accessoryView = scrollView
        alert.addButton(withTitle: "취소")

        alert.beginSheetModal(for: window) { [target] _ in
            withExtendedLifetime(target) {}
        }
        sheetWindow = alert.window
    }

    static func triggerManualFill(model: LoginBrowserModel) {
        guard let appModel = model.appModel,
              appModel.selectedTab == .browser,
              appModel.browser === model,
              let webView = model.webView,
              let window = webView.window,
              window.isKeyWindow,
              window.attachedSheet == nil,
              let currentURL = webView.url,
              let scheme = currentURL.scheme?.lowercased(),
              (scheme == "https" || scheme == "http"),
              let popupURL = model.popupCommittedURL,
              popupURL == currentURL,
              let origin = SiteCredentialStore.canonicalOrigin(for: currentURL) else { return }

        let accounts = SiteCredentialStore.accounts(forOrigin: origin)
        guard !accounts.isEmpty else { return }

        let capture = SiteCredentialCapture(model: model)
        capture.handleFocusAutofill(origin: origin, generation: model.generation, webView: webView, forcePicker: true)
    }
}
