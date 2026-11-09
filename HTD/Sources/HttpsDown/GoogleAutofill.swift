import SwiftUI
import WebKit
import Security

/// Optional Google password autofill for the app's own browser.
///
/// * The user types the password into the native SecureField below; it is stored only as this app's own Keychain item
///   (service/account fixed here). Nothing from Safari, Chrome or the system password store is read, and nothing from
///   a page (DOM) is ever scraped or saved.
/// * Fill happens only in the main frame of exactly https://accounts.google.com (default port, no userinfo), is
///   re-checked inside the page (`location.origin`, top window), only into an empty visible password input, and
///   never presses Next/submit or touches 2-step verification. The secret travels as a `callAsyncJavaScript`
///   argument into an isolated world (never interpolated into source); the page-side result is only a count.
/// * This is separate from login persistence: the persistent WebKit store keeps cookies; this item only fills a field.
enum GoogleCredentialStore {
    static let service = "com.hanstree.HttpsDown.google-autofill"
    static let account = "accounts.google.com"
    private static let enabledKey = "googleAutofillEnabled"
    /// Non-secret mirror of the bound Google address, so the setup sheet and the page probe never have to open the
    /// Keychain item (and trigger its access prompt). The Keychain record stays the authority at fill time.
    private static let accountKey = "googleAutofillAccount"

    /// What the single Keychain item holds: the Google account the password belongs to, and the password itself.
    private struct Record: Codable { var account: String; var password: String }

    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    /// Bound Google address (lower case), nil when nothing is saved. Not a secret.
    static var savedAccount: String? {
        let a = UserDefaults.standard.string(forKey: accountKey)
        return (a?.isEmpty ?? true) ? nil : a
    }

    static var hasSavedPassword: Bool { savedAccount != nil }

    static func normalized(_ account: String) -> String { account.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    /// Update-in-place: a failed save never removes the last good item (no delete-then-add).
    @discardableResult
    static func save(account email: String, password: String) -> Bool {
        let email = normalized(email)
        guard email.contains("@"), !password.isEmpty,
              let data = try? JSONEncoder().encode(Record(account: email, password: password)) else { return false }
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var q = query
            q[kSecValueData as String] = data
            q[kSecAttrLabel as String] = "HTD Google 비밀번호 자동 입력"
            q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(q as CFDictionary, nil)
        }
        guard status == errSecSuccess else { return false }
        UserDefaults.standard.set(email, forKey: accountKey)
        return true
    }

    @discardableResult
    static func delete() -> Bool {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { return false }
        UserDefaults.standard.removeObject(forKey: accountKey)
        return true
    }

    fileprivate static func read() -> (account: String, password: String)? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data,
              let r = try? JSONDecoder().decode(Record.self, from: data) else { return nil }
        return (r.account, r.password)
    }
}

/// Fills the Google password step for one browser tab. Holds no secret between attempts.
@MainActor
final class GoogleAutofill {
    private static let world = WKContentWorld.world(name: "HttpsDownGoogleFill")
    private var generation = 0
    /// Short status for the user (never contains an address or a password).
    var onNotice: ((String) -> Void)?

    /// Exact https://accounts.google.com:443 only: rejects userinfo, other ports and look-alike hosts.
    static func isGoogleSignIn(_ url: URL?) -> Bool {
        guard let url = url, let c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        return c.scheme?.lowercased() == "https" && c.host?.lowercased() == "accounts.google.com"
            && (c.port == nil || c.port == 443) && c.user == nil && c.password == nil
    }

    /// Call when a page finished loading or the user just saved/enabled. Google's username → password step happens
    /// without a navigation, so the probe repeats briefly (bounded, stops on view replacement or after a fill).
    func pageFinished(in webView: WKWebView, isCurrent: @escaping () -> Bool) {
        generation += 1
        guard GoogleCredentialStore.isEnabled, Self.isGoogleSignIn(webView.url) else { return }
        attempt(webView, generation: generation, left: 90, isCurrent: isCurrent)
    }

    func cancel() { generation += 1 }

    /// '지금 채우기': explicit user choice. Ignores only the enabled switch; the exact account match still applies.
    func fillNow(in webView: WKWebView) {
        generation += 1
        guard Self.isGoogleSignIn(webView.url) else { return }
        attempt(webView, generation: generation, left: 1, isCurrent: { true }, force: true)
    }

    private func attempt(_ webView: WKWebView, generation gen: Int, left: Int, isCurrent: @escaping () -> Bool,
                         force: Bool = false) {
        guard gen == generation, left > 0, isCurrent(), force || GoogleCredentialStore.isEnabled,
              Self.isGoogleSignIn(webView.url), let bound = GoogleCredentialStore.savedAccount else { return }
        let page = webView.url
        // Secret-free probe first (it may type the non-secret address into an empty username box); the Keychain is
        // only read when an empty password field is actually there and the page's account is the bound one.
        webView.callAsyncJavaScript(Self.script, arguments: ["mode": "probe", "email": bound, "pw": ""],
                                    in: nil, in: Self.world) { [weak self, weak webView] result in
            MainActor.assumeIsolated {
                guard let self = self, let webView = webView, gen == self.generation, isCurrent(),
                      force || GoogleCredentialStore.isEnabled, Self.isGoogleSignIn(webView.url) else { return }
                var code = 0
                if case .success(let v) = result { code = v as? Int ?? 0 }
                if code == 2 || code == 3 {
                    self.onNotice?(code == 2
                        ? "현재 로그인 중인 Google 계정이 저장된 계정과 달라 비밀번호를 자동 입력하지 않았습니다. 페이지에서 저장된 계정으로 로그인하거나, 키 버튼에서 저장한 계정 정보를 변경해 주세요."
                        : "현재 Google 계정을 확인할 수 없어 비밀번호를 자동 입력하지 않았습니다. 페이지에서 저장된 계정으로 로그인하거나, 키 버튼에서 저장한 계정 정보를 변경해 주세요.")
                    return
                }
                if code == 1, webView.url == page, let rec = GoogleCredentialStore.read(), rec.account == bound {
                    // The system Keychain prompt may have let state change: re-validate before dispatching the secret.
                    guard gen == self.generation, isCurrent(), force || GoogleCredentialStore.isEnabled,
                          Self.isGoogleSignIn(webView.url), webView.url == page,
                          GoogleCredentialStore.savedAccount == bound else { return }
                    var secret: String? = rec.password
                    webView.callAsyncJavaScript(Self.script, arguments: ["mode": "fill", "email": rec.account, "pw": secret ?? ""],
                                                in: nil, in: Self.world) { _ in }
                    secret = nil
                    return
                }
                guard left > 1 else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self, weak webView] in
                    guard let self = self, let webView = webView else { return }
                    self.attempt(webView, generation: gen, left: left - 1, isCurrent: isCurrent, force: force)
                }
            }
        }
    }

    /// Returns only a status code: 0 nothing to do, 1 empty password field ready (and, for the fill modes, filled),
    /// 2 page shows a different account, 3 page account unknown, 4 empty username box filled with the bound address.
    /// Origin and top window are re-checked here; the account match is decided inside the page, nothing is returned.
    private static let script = """
        try {
          if (window !== window.top || location.origin !== 'https://accounts.google.com') return 0;
          function usable(el) {
            var r = el.getBoundingClientRect(), st = getComputedStyle(el);
            return !(el.disabled || el.readOnly || r.width < 2 || r.height < 2 || st.visibility === 'hidden' || st.display === 'none');
          }
          function put(el, v) {
            Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set.call(el, v);
            el.dispatchEvent(new Event('input', { bubbles: true }));
            el.dispatchEvent(new Event('change', { bubbles: true }));
          }
          var pws = [], list = document.querySelectorAll('input[type=password]');
          for (var i = 0; i < list.length; i++) if (list[i].value === '' && usable(list[i])) pws.push(list[i]);
          if (pws.length === 0) {
            var u = document.querySelector('input#identifierId, input[type=email][name=identifier]');
            if (u && u.value === '' && usable(u) && email) { put(u, email); return 4; }
            return 0;
          }
          {
            var shown = '';
            var chip = document.querySelector('[data-email]');
            if (chip) shown = chip.getAttribute('data-email') || '';
            if (!shown) { var idf = document.querySelector('#identifierId'); if (idf) shown = idf.value || ''; }
            shown = shown.trim().toLowerCase();
            if (!shown) return 3;
            if (shown !== String(email).trim().toLowerCase()) return 2;
          }
          if (mode === 'fill') for (var j = 0; j < pws.length; j++) put(pws[j], pw);
          return 1;
        } catch (e) { return 0; }
        """
}

/// Setup/management sheet: separate password entry, enable switch, delete. Clearly not the browser login.
struct GoogleAutofillSheet: View {
    var fillNow: () -> Void
    var arm: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var account = GoogleCredentialStore.savedAccount ?? ""
    @State private var password = ""
    @State private var enabled = GoogleCredentialStore.isEnabled
    @State private var saved = GoogleCredentialStore.hasSavedPassword
    @State private var message = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Google 비밀번호 자동 입력 (보조 기능)").font(.headline)
            VStack(alignment: .leading, spacing: 4) {
                Text("• 사이트 로그인은 브라우저 화면에서 사용자가 직접 진행합니다.")
                Text("• 이 기능은 accounts.google.com 로그인 페이지의 빈 비밀번호 칸만 채우는 보조 기능입니다.")
                Text("• Safari, Chrome 등 다른 브라우저 비밀번호는 읽지 않으며, 이 앱 전용 키체인에만 안전하게 보관됩니다.")
                Text("• 자격증명 추출, 자동 로그인 제출(클릭), 2단계 인증 변경은 일절 수행하지 않습니다.")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            TextField("Google 계정 (이메일)", text: $account)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Google 계정 이메일 입력")
            SecureField("Google 비밀번호", text: $password)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Google 비밀번호 입력")
            Toggle("accounts.google.com에서 자동으로 채우기 사용", isOn: $enabled)
                .onChange(of: enabled) { _, value in
                    GoogleCredentialStore.isEnabled = value
                    if value { arm() }
                }
            Text(saved ? "저장됨 (이 앱 전용 키체인 보관, 계정: \(GoogleCredentialStore.savedAccount ?? ""))" : "저장된 비밀번호 없음").font(.caption)
            if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.secondary) }
            HStack {
                Button("저장") {
                    if GoogleCredentialStore.save(account: account, password: password) {
                        password = ""
                        saved = true
                        message = "키체인에 안전하게 저장했습니다."
                        if enabled { arm() }
                    } else {
                        message = "저장하지 못했습니다. 계정은 이메일 형식이어야 하며, 이전에 저장한 항목은 그대로 유지됩니다."
                    }
                }.disabled(password.isEmpty || !account.contains("@"))
                Button("비밀번호 삭제", role: .destructive) {
                    message = GoogleCredentialStore.delete() ? "저장된 비밀번호를 삭제했습니다." : "삭제하지 못했습니다."
                    saved = GoogleCredentialStore.hasSavedPassword
                    if !saved { account = "" }
                }.disabled(!saved)
                Button("지금 채우기") { fillNow(); dismiss() }.disabled(!saved)
                Spacer()
                Button("닫기") { password = ""; dismiss() }
            }
        }
        .padding(16)
        .frame(width: 440)
        .onDisappear { password = "" }
    }
}
