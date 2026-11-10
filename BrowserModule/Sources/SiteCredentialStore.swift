import SwiftUI
import WebKit
import Security

/// Site-specific credential storage reusing GoogleAutofill patterns.
///
/// Security constraints:
/// - Exact committed HTTPS origin including port (e.g. "https://example.com:443" or "https://example.com").
/// - User credentials are saved ONLY through explicit native UI actions (never scraped or auto-saved from DOM).
/// - Secrets stored in macOS Keychain with kSecAttrAccessibleWhenUnlockedThisDeviceOnly.
/// - Keychain service: "com.hanstree.HttpsDown.site-autofill".
/// - Account key: canonical exact HTTPS origin + "\0" + username.
/// - Non-secret account list mirrored in UserDefaults for UI and pre-fill probe, avoiding premature Keychain prompts.
/// - Deliberate user action ("지금 채우기") fills visible empty username and password fields in the main frame.
/// - Passwords stored solely in Keychain (never in UserDefaults or logs).
/// - Never logs secrets or passwords.
public enum SiteCredentialStore {
    public static let service = "com.hanstree.HttpsDown.site-autofill"
    private static let accountsIndexKey = "siteAutofillAccountsIndex" // [Origin: [Username]]

    public struct Record: Codable {
        public var origin: String
        public var username: String
        public var password: String

        public init(origin: String, username: String, password: String) {
            self.origin = origin
            self.username = username
            self.password = password
        }
    }

    /// Exact HTTPS origin including port normalization: scheme://host[:port]. Rejects userinfo, paths, non-HTTPS.
    public static func canonicalOrigin(for url: URL?) -> String? {
        guard let url = url, let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        guard comps.scheme?.lowercased() == "https",
              let host = comps.host?.lowercased(), !host.isEmpty,
              comps.user == nil, comps.password == nil else { return nil }
        let port = comps.port
        if let p = port, p != 443 {
            return "https://\(host):\(p)"
        } else {
            return "https://\(host)"
        }
    }

    private static var index: [String: [String]] {
        get { HTDBrowserDefaults.standard.dictionary(forKey: accountsIndexKey) as? [String: [String]] ?? [:] }
        set { HTDBrowserDefaults.standard.set(newValue, forKey: accountsIndexKey) }
    }

    public static func accounts(forOrigin origin: String) -> [String] {
        let trimmed = origin.trimmingCharacters(in: .whitespacesAndNewlines)
        return index[trimmed] ?? []
    }

    public static func savedOrigins() -> [String] {
        Array(index.keys).sorted()
    }

    public static func hasSavedCredential(forOrigin origin: String) -> Bool {
        !accounts(forOrigin: origin).isEmpty
    }

    private static func keychainAccountKey(origin: String, username: String) -> String {
        "\(Data(origin.utf8).base64EncodedString()):\(Data(username.utf8).base64EncodedString())"
    }

    private static func query(origin: String, username: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: keychainAccountKey(origin: origin, username: username)
        ]
    }

    public static func read(origin: String, username: String) -> Record? {
        let trimmedOrigin = origin.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedUser = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedOrigin.isEmpty, !trimmedUser.isEmpty else { return nil }

        var q = query(origin: trimmedOrigin, username: trimmedUser)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data,
              let password = String(data: data, encoding: .utf8) else {
            return nil
        }
        return Record(origin: trimmedOrigin, username: trimmedUser, password: password)
    }

    @discardableResult
    public static func save(origin: String, username: String, password: String, replacing: Bool) -> Bool {
        guard let url = URL(string: origin), let canonical = canonicalOrigin(for: url) else { return false }
        let cleanUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanUsername.isEmpty, !password.isEmpty else { return false }
        guard let passwordData = password.data(using: .utf8) else { return false }

        var q = query(origin: canonical, username: cleanUsername)
        let status: OSStatus
        if replacing {
            status = SecItemUpdate(q as CFDictionary, [kSecValueData as String: passwordData] as CFDictionary)
        } else {
            q[kSecValueData as String] = passwordData
            q[kSecAttrLabel as String] = "HTD 사이트 계정"
            q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(q as CFDictionary, nil)
        }
        guard status == errSecSuccess else { return false }

        var idx = index
        var userList = idx[canonical] ?? []
        if !userList.contains(cleanUsername) {
            userList.append(cleanUsername)
            idx[canonical] = userList
            index = idx
        }
        return true
    }

    @discardableResult
    public static func replace(origin: String, oldUsername: String, username: String, password: String) -> Bool {
        guard let url = URL(string: origin), let canonical = canonicalOrigin(for: url) else { return false }
        let cleanOld = oldUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanNew = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanOld.isEmpty, !cleanNew.isEmpty, !password.isEmpty else { return false }
        guard cleanOld != cleanNew else { return false }
        guard let passwordData = password.data(using: .utf8) else { return false }

        let currentAccounts = accounts(forOrigin: canonical)
        guard currentAccounts.contains(cleanOld), !currentAccounts.contains(cleanNew) else { return false }

        let q = query(origin: canonical, username: cleanOld)
        let newKey = keychainAccountKey(origin: canonical, username: cleanNew)
        let attributesToUpdate: [String: Any] = [
            kSecAttrAccount as String: newKey,
            kSecValueData as String: passwordData
        ]

        let status = SecItemUpdate(q as CFDictionary, attributesToUpdate as CFDictionary)
        guard status == errSecSuccess else { return false }

        var idx = index
        if var userList = idx[canonical] {
            if let i = userList.firstIndex(of: cleanOld) {
                userList[i] = cleanNew
            } else {
                userList.append(cleanNew)
            }
            idx[canonical] = userList
            index = idx
        }
        return true
    }

    @discardableResult
    public static func delete(origin: String, username: String) -> Bool {
        let trimmedOrigin = origin.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedUser = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedOrigin.isEmpty, !trimmedUser.isEmpty else { return false }

        let q = query(origin: trimmedOrigin, username: trimmedUser)
        let status = SecItemDelete(q as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { return false }

        var idx = index
        if var userList = idx[trimmedOrigin] {
            userList.removeAll { $0 == trimmedUser }
            if userList.isEmpty {
                idx.removeValue(forKey: trimmedOrigin)
            } else {
                idx[trimmedOrigin] = userList
            }
            index = idx
        }
        return true
    }
}

/// Helper that handles filling site credentials safely into visible main-frame inputs.
@MainActor
public final class SiteAutofill {
    private static let world = WKContentWorld.world(name: "HttpsDownSiteFill")

    public static func fill(
        in webView: WKWebView,
        origin: String,
        username: String,
        isCurrent: @escaping () -> Bool,
        onNotice: @escaping (String) -> Void
    ) {
        guard isCurrent() else {
            onNotice("페이지 또는 탭 상태가 바뀌어 입력을 취소했습니다.")
            return
        }

        guard let currentURL = webView.url,
              let canonical = SiteCredentialStore.canonicalOrigin(for: currentURL),
              canonical == origin else {
            onNotice("현재 페이지 주소와 저장된 사이트 주소가 달라 채우지 못했습니다.")
            return
        }

        // Revalidate isCurrent before Keychain access
        guard isCurrent() else {
            onNotice("페이지 또는 탭 상태가 바뀌어 입력을 취소했습니다.")
            return
        }

        guard let rec = SiteCredentialStore.read(origin: canonical, username: username) else {
            onNotice("저장된 로그인 정보를 키체인에서 읽지 못했습니다.")
            return
        }

        // Revalidate isCurrent after Keychain access
        guard isCurrent() else {
            onNotice("키체인 확인 중 페이지 또는 탭이 바뀌어 입력을 취소했습니다.")
            return
        }

        // Check again after Keychain access to guard against tab/navigation switch during prompt
        guard let recheckedURL = webView.url,
              let recheckedOrigin = SiteCredentialStore.canonicalOrigin(for: recheckedURL),
              recheckedOrigin == canonical else {
            onNotice("키체인 확인 중 페이지가 바뀌어 입력을 취소했습니다.")
            return
        }

        var secretPassword: String? = rec.password
        let fillUsername = rec.username

        let script = """
        return (function() {
            try {
                if (window !== window.top) return 0;
                if (location.origin !== expectedOrigin) return 0;

                function isCandidateInput(el) {
                    if (!el || el.disabled || el.readOnly) return false;
                    var st = getComputedStyle(el);
                    if (st.visibility === 'hidden' || st.display === 'none') return false;
                    var r = el.getBoundingClientRect();
                    if (r.width < 2 || r.height < 2) return false;
                    return true;
                }

                function checkEligibleForm(form) {
                    if (!form || !(form instanceof HTMLFormElement)) return null;

                    // Validate form method: must be POST (effective method defaults to GET if empty, reject non-POST)
                    var formMethod = (form.getAttribute('method') || form.method || 'get').trim().toLowerCase();
                    if (formMethod !== 'post') return null;

                    // Validate form target: must not target non-self (e.g. _blank, _parent, _top, external frame)
                    // Also check document <base target="..."> if form does not specify target
                    var formTargetAttr = form.getAttribute('target');
                    var effectiveTarget = '';
                    if (formTargetAttr !== null && formTargetAttr.trim() !== '') {
                        effectiveTarget = formTargetAttr.trim().toLowerCase();
                    } else {
                        var baseEl = document.querySelector('base[target]');
                        if (baseEl) {
                            var baseTarget = baseEl.getAttribute('target');
                            if (baseTarget !== null && baseTarget.trim() !== '') {
                                effectiveTarget = baseTarget.trim().toLowerCase();
                            }
                        }
                    }
                    if (effectiveTarget !== '' && effectiveTarget !== '_self') return null;

                    // Validate form action: must resolve to valid same-origin HTTPS
                    // Account for document.baseURI and form.action
                    var rawAction = form.getAttribute('action');
                    var baseForAction = document.baseURI || window.location.href;
                    var resolvedActionUrl;
                    try {
                        resolvedActionUrl = new URL(rawAction !== null ? rawAction : (form.action || ''), baseForAction);
                    } catch(e) {
                        return null;
                    }
                    if (resolvedActionUrl.protocol !== 'https:' || resolvedActionUrl.origin !== expectedOrigin) {
                        return null;
                    }

                    // Refuse forms with unsafe submit button formAction/formTarget/formMethod overrides
                    var submitButtons = document.querySelectorAll('button, input[type=submit], input[type=image]');
                    for (var sb = 0; sb < submitButtons.length; sb++) {
                        var btn = submitButtons[sb];
                        if (btn.form !== form || (btn.type !== 'submit' && btn.type !== 'image')) continue;
                        if (btn.hasAttribute('formmethod')) {
                            var bMethod = (btn.getAttribute('formmethod') || '').trim().toLowerCase();
                            if (bMethod !== 'post') return null;
                        }
                        if (btn.hasAttribute('formtarget')) {
                            var bTarget = (btn.getAttribute('formtarget') || '').trim().toLowerCase();
                            if (bTarget !== '' && bTarget !== '_self') return null;
                        }
                        if (btn.hasAttribute('formaction')) {
                            var bAction = btn.getAttribute('formaction');
                            try {
                                var resolvedBtnAction = new URL(bAction !== null ? bAction : '', baseForAction);
                                if (resolvedBtnAction.protocol !== 'https:' || resolvedBtnAction.origin !== expectedOrigin) {
                                    return null;
                                }
                            } catch(e) {
                                return null;
                            }
                        }
                    }

                    // Must have exactly one visible eligible password field
                    var formPwInputs = form.querySelectorAll('input[type=password]');
                    var visibleFormPws = [];
                    for (var p = 0; p < formPwInputs.length; p++) {
                        if (formPwInputs[p].form === form && isCandidateInput(formPwInputs[p])) {
                            visibleFormPws.push(formPwInputs[p]);
                        }
                    }
                    if (visibleFormPws.length !== 1) return null;
                    var pwInput = visibleFormPws[0];

                    // Reject new-password explicitly
                    var pwAC = (pwInput.getAttribute('autocomplete') || '').toLowerCase().trim();
                    if (pwAC.split(/\\s+/).includes('new-password')) return null;

                    // Must have recognizable username candidate
                    var formInputs = form.querySelectorAll('input');
                    var strongCandidates = [];
                    var fallbackCandidates = [];
                    var strongNames = ['username', 'user', 'login', 'userid', 'login_id', 'loginid', 'member_id', 'memberid', 'mb_id', 'id', 'email'];

                    for (var u = 0; u < formInputs.length; u++) {
                        var inp = formInputs[u];
                        if (inp === pwInput || inp.form !== form) continue;
                        var t = (inp.getAttribute('type') || inp.type || 'text').toLowerCase();
                        if (t === 'hidden' || t === 'password' || t === 'submit' || t === 'button' || t === 'reset' || t === 'checkbox' || t === 'radio' || t === 'file' || t === 'image' || t === 'search') {
                            continue;
                        }
                        if (inp.disabled || inp.readOnly) continue;
                        if (!isCandidateInput(inp)) continue;

                        var ac = (inp.getAttribute('autocomplete') || '').toLowerCase().trim();
                        var name = (inp.name || '').toLowerCase();
                        var id = (inp.id || '').toLowerCase();

                        var isStrong = false;
                        if (ac === 'username' || ac.split(/\\s+/).indexOf('username') !== -1) {
                            isStrong = true;
                        } else if (ac === 'email' || ac.split(/\\s+/).indexOf('email') !== -1) {
                            isStrong = true;
                        } else if (strongNames.indexOf(name) !== -1 || strongNames.indexOf(id) !== -1) {
                            isStrong = true;
                        }

                        if (isStrong) {
                            strongCandidates.push(inp);
                        } else if (t === 'text' || t === 'email' || t === 'tel') {
                            fallbackCandidates.push(inp);
                        }
                    }

                    var candidateUsername = null;
                    if (strongCandidates.length === 1) {
                        candidateUsername = strongCandidates[0];
                    } else if (strongCandidates.length === 0 && fallbackCandidates.length === 1) {
                        candidateUsername = fallbackCandidates[0];
                    } else {
                        return null;
                    }

                    return {
                        form: form,
                        pwInput: pwInput,
                        candidateUsername: candidateUsername
                    };
                }

                // Check focused element's form first
                var targetFormInfo = null;
                var activeEl = document.activeElement;
                if (activeEl && activeEl.form) {
                    var focusedInfo = checkEligibleForm(activeEl.form);
                    if (focusedInfo) {
                        targetFormInfo = focusedInfo;
                    }
                }

                // If no focused eligible form, find unique eligible form across all forms in document
                if (!targetFormInfo) {
                    var docForms = document.querySelectorAll('form');
                    var eligibleForms = [];
                    for (var f = 0; f < docForms.length; f++) {
                        var info = checkEligibleForm(docForms[f]);
                        if (info) {
                            eligibleForms.push(info);
                        }
                    }

                    if (eligibleForms.length > 1) {
                        function isExposed(input) {
                            var rect = input.getBoundingClientRect();
                            var x = rect.left + rect.width / 2;
                            var y = rect.top + rect.height / 2;
                            return document.elementFromPoint(x, y) === input;
                        }
                        eligibleForms = eligibleForms.filter(function(info) {
                            return isExposed(info.candidateUsername) && isExposed(info.pwInput);
                        });
                        if (eligibleForms.length !== 1) return 4;
                    }

                    if (eligibleForms.length === 1) {
                        targetFormInfo = eligibleForms[0];
                    } else {
                        // Check if there are visible passwords anywhere to return appropriate code
                        var allPwInputs = document.querySelectorAll('input[type=password]');
                        var anyVisiblePw = false;
                        for (var i = 0; i < allPwInputs.length; i++) {
                            if (isCandidateInput(allPwInputs[i])) {
                                anyVisiblePw = true;
                                break;
                            }
                        }
                        return anyVisiblePw ? 4 : 1;
                    }
                }

                var pwInput = targetFormInfo.pwInput;
                var candidateUsername = targetFormInfo.candidateUsername;

                // Unambiguous matching username field must be blank or match selected user
                var currentVal = (candidateUsername.value || '').trim();
                if (currentVal !== '' && currentVal !== userVal) {
                    return 4;
                }

                function setNativeValue(el, v) {
                    var desc = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value');
                    if (desc && desc.set) {
                        desc.set.call(el, v);
                    } else {
                        el.value = v;
                    }
                }

                // Set both native values before dispatching any input/change events to avoid page mutation between assignments
                setNativeValue(candidateUsername, userVal);
                setNativeValue(pwInput, passVal);

                candidateUsername.dispatchEvent(new Event('input', { bubbles: true }));
                candidateUsername.dispatchEvent(new Event('change', { bubbles: true }));
                pwInput.dispatchEvent(new Event('input', { bubbles: true }));
                pwInput.dispatchEvent(new Event('change', { bubbles: true }));

                // Verify actual populated values after events
                if (candidateUsername.value !== userVal || pwInput.value !== passVal) {
                    return 4;
                }

                return 2;
            } catch(e) {
                return -1;
            }
        })();
        """

        webView.callAsyncJavaScript(
            script,
            arguments: [
                "expectedOrigin": canonical,
                "userVal": fillUsername,
                "passVal": secretPassword ?? ""
            ],
            in: nil,
            in: world
        ) { result in
            MainActor.assumeIsolated {
                secretPassword = nil
                // Revalidate isCurrent after probe
                guard isCurrent() else {
                    onNotice("입력 실행 중 탭 또는 페이지가 바뀌었습니다.")
                    return
                }

                switch result {
                case .success(let code):
                    if let c = code as? Int {
                        if c == 2 {
                            onNotice("저장된 아이디와 비밀번호를 입력했습니다.")
                        } else if c == 1 {
                            onNotice("페이지에서 비밀번호 입력 칸을 찾지 못했습니다.")
                        } else if c == 3 {
                            onNotice("전송 주소(Action)가 사이트 주소와 달라 안전을 위해 입력을 취소했습니다.")
                        } else {
                            onNotice("안전을 위해 입력을 건너뛰었습니다.")
                        }
                    }
                case .failure:
                    onNotice("페이지에 자동 입력하지 못했습니다.")
                }
            }
        }
    }
}

/// Settings and management sheet for site-specific credentials.
struct SiteCredentialManagementSheet: View {
    @ObservedObject var model: LoginBrowserModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.bkPalette) private var palette

    @State private var currentOrigin: String = ""
    @State private var selectedUsername: String = ""
    @State private var usernameInput: String = ""
    @State private var passwordInput: String = ""
    @State private var noticeMessage: String = ""
    @State private var savedOrigins: [String] = []

    @State private var showOverwriteAlert: Bool = false
    @State private var showDeleteAlert: Bool = false
    @State private var showRenameAlert: Bool = false
    @State private var targetOriginToDelete: String = ""
    @State private var targetUserToDelete: String = ""

    // Dedicated account edit state
    @State private var editingOrigin: String? = nil
    @State private var editingOriginalUser: String = ""

    init(model: LoginBrowserModel) {
        self.model = model
    }

    private func refreshData() {
        savedOrigins = SiteCredentialStore.savedOrigins()
        if !currentOrigin.isEmpty {
            let accts = SiteCredentialStore.accounts(forOrigin: currentOrigin)
            if !accts.contains(selectedUsername) {
                selectedUsername = accts.first ?? ""
            }
        }
    }

    private func loadSelectedCredential() {
        guard !currentOrigin.isEmpty, !selectedUsername.isEmpty else {
            usernameInput = ""
            passwordInput = ""
            return
        }
        usernameInput = selectedUsername
        // Do not read Keychain on picker selection. Blank replacement field; retain prior password on explicit save if blank.
        passwordInput = ""
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("사이트별 로그인 계정 관리 (키체인 보관)")
                .font(.headline)
                .foregroundColor(palette.textColor)

            VStack(alignment: .leading, spacing: 4) {
                Text("• HTTPS 보안 주소(포트 포함)별로 계정을 macOS 키체인에 안전하게 저장합니다.")
                Text("• 지원되는 양식에서 사용자가 로그인/제출한 후 저장을 제안할 수 있으며, 사용자 동의 없이 임의로 저장하지 않습니다.")
                Text("• 저장된 비밀번호는 암호화되어 보호되며 화면이나 로그에 노출되지 않습니다.")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            Divider()

            if let targetOrigin = editingOrigin {
                VStack(alignment: .leading, spacing: 10) {
                    Text("계정 수정").font(.subheadline.bold())

                    HStack {
                        Text("사이트 주소:").font(.caption.bold())
                        Text(targetOrigin).font(.caption).foregroundStyle(.secondary)
                    }

                    HStack {
                        Text("기존 아이디:").font(.caption.bold())
                        Text(editingOriginalUser).font(.caption).foregroundStyle(.secondary)
                    }

                    HStack(spacing: 8) {
                        TextField("아이디 또는 이메일", text: $usernameInput)
                            .textFieldStyle(.roundedBorder)
                        SecureField("비밀번호 (비워두면 기존 유지)", text: $passwordInput)
                            .textFieldStyle(.roundedBorder)

                        Button("저장") {
                            performEditSave()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(usernameInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                        Button("취소") {
                            cancelEditing()
                        }
                    }
                }
                .padding(10)
                .background(palette.surfaceColor)
                .cornerRadius(8)
            } else if !currentOrigin.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("현재 사이트: \(currentOrigin)").font(.subheadline.bold())

                    let currentAccounts = SiteCredentialStore.accounts(forOrigin: currentOrigin)
                    if !currentAccounts.isEmpty {
                        HStack {
                            Text("계정 선택:").font(.caption.bold())
                            Picker("계정 선택", selection: $selectedUsername) {
                                ForEach(currentAccounts, id: \.self) { acct in
                                    Text(acct).tag(acct)
                                }
                            }
                            .pickerStyle(.menu)
                            .onChange(of: selectedUsername) { _ in
                                loadSelectedCredential()
                            }
                        }
                    }

                    HStack(spacing: 8) {
                        TextField("아이디 또는 이메일", text: $usernameInput)
                            .textFieldStyle(.roundedBorder)
                        SecureField("비밀번호 (변경 시 입력)", text: $passwordInput)
                            .textFieldStyle(.roundedBorder)

                        Button("저장/변경") {
                            let cleanUser = usernameInput.trimmingCharacters(in: .whitespacesAndNewlines)
                            let existing = SiteCredentialStore.accounts(forOrigin: currentOrigin)
                            if existing.contains(cleanUser) && cleanUser == selectedUsername {
                                showOverwriteAlert = true
                            } else if existing.contains(cleanUser) {
                                showOverwriteAlert = true
                            } else {
                                performSave(replacing: false)
                            }
                        }
                        .disabled(usernameInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (passwordInput.isEmpty && !SiteCredentialStore.accounts(forOrigin: currentOrigin).contains(usernameInput.trimmingCharacters(in: .whitespacesAndNewlines))))

                        let cleanNewName = usernameInput.trimmingCharacters(in: .whitespacesAndNewlines)
                        let accountsForOrigin = SiteCredentialStore.accounts(forOrigin: currentOrigin)
                        Button("아이디 변경") {
                            showRenameAlert = true
                        }
                        .disabled(cleanNewName.isEmpty || selectedUsername.isEmpty || cleanNewName == selectedUsername || !accountsForOrigin.contains(selectedUsername) || accountsForOrigin.contains(cleanNewName))
                    }

                    if !currentAccounts.isEmpty {
                        HStack {
                            Button("현재 페이지에 지금 채우기") {
                                performAutofill(origin: currentOrigin, username: selectedUsername.isEmpty ? usernameInput : selectedUsername)
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(selectedUsername.isEmpty && usernameInput.isEmpty)

                            Button("계정 삭제", role: .destructive) {
                                let userDel = selectedUsername.isEmpty ? usernameInput : selectedUsername
                                guard !userDel.isEmpty else { return }
                                targetOriginToDelete = currentOrigin
                                targetUserToDelete = userDel
                                showDeleteAlert = true
                            }
                        }
                    }
                }
                .padding(10)
                .background(palette.surfaceColor)
                .cornerRadius(8)
            } else {
                Text("HTTPS 페이지가 열려 있을 때 현재 사이트 계정을 저장할 수 있습니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !noticeMessage.isEmpty {
                Text(noticeMessage)
                    .font(.caption)
                    .foregroundColor(palette.accentColor)
            }

            Divider()

            Text("저장된 사이트 계정 목록 (\(savedOrigins.count)개 사이트)")
                .font(.subheadline.bold())

            if savedOrigins.isEmpty {
                Text("저장된 계정이 없습니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(12)
                Spacer()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(savedOrigins, id: \.self) { origin in
                            let accts = SiteCredentialStore.accounts(forOrigin: origin)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(origin).font(.caption.bold())
                                ForEach(accts, id: \.self) { acct in
                                    HStack {
                                        Text("• \(acct)")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                        Spacer()
                                        Button("수정") {
                                            startEditing(origin: origin, account: acct)
                                        }
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)

                                        Button(role: .destructive) {
                                            targetOriginToDelete = origin
                                            targetUserToDelete = acct
                                            showDeleteAlert = true
                                        } label: {
                                            Image(systemName: "trash").font(.caption2)
                                        }
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)
                                        .accessibilityLabel("\(origin)의 \(acct) 삭제")
                                    }
                                }
                            }
                            .padding(6)
                            .background(palette.surface2Color)
                            .cornerRadius(6)
                        }
                    }
                }
                .frame(minHeight: 150, maxHeight: .infinity)
            }

            HStack {
                Spacer()
                Button("닫기") {
                    passwordInput = ""
                    cancelEditing()
                    dismiss()
                }
            }
        }
        .padding(18)
        .frame(minWidth: 520, idealWidth: 680, maxWidth: .infinity, minHeight: 520, idealHeight: 620, maxHeight: .infinity)
        .onAppear {
            let initialURL = model.popupCommittedURL ?? model.currentURL
            if let canon = SiteCredentialStore.canonicalOrigin(for: initialURL) {
                currentOrigin = canon
                let accts = SiteCredentialStore.accounts(forOrigin: canon)
                selectedUsername = accts.first ?? ""
                loadSelectedCredential()
            }
            refreshData()
        }
        .onDisappear {
            passwordInput = ""
            cancelEditing()
        }
        .alert("계정 덮어쓰기 확인", isPresented: $showOverwriteAlert) {
            Button("덮어쓰기", role: .destructive) {
                performSave(replacing: true)
            }
            Button("취소", role: .cancel) {}
        } message: {
            Text("이미 존재하는 계정(\(usernameInput))입니다. 비밀번호를 새로 덮어쓰시겠습니까?")
        }
        .alert("계정 삭제 확인", isPresented: $showDeleteAlert) {
            Button("삭제", role: .destructive) {
                performDelete(origin: targetOriginToDelete, username: targetUserToDelete)
            }
            Button("취소", role: .cancel) {}
        } message: {
            Text("\(targetOriginToDelete) 사이트의 계정 '\(targetUserToDelete)'을(를) 삭제하시겠습니까?")
        }
        .alert("계정 아이디 변경 확인", isPresented: $showRenameAlert) {
            Button("변경", role: .destructive) {
                performRename()
            }
            Button("취소", role: .cancel) {}
        } message: {
            let cleanNew = usernameInput.trimmingCharacters(in: .whitespacesAndNewlines)
            Text("기존 아이디 '\(selectedUsername)'을(를) 새 아이디 '\(cleanNew)'(으)로 변경하시겠습니까?")
        }
    }

    private func startEditing(origin: String, account: String) {
        editingOrigin = origin
        editingOriginalUser = account
        usernameInput = account
        passwordInput = ""
    }

    private func cancelEditing() {
        editingOrigin = nil
        editingOriginalUser = ""
        passwordInput = ""
        loadSelectedCredential()
    }

    private func performEditSave() {
        guard let origin = editingOrigin else { return }
        let cleanOld = editingOriginalUser.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanNew = usernameInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanNew.isEmpty else {
            noticeMessage = "아이디를 입력해 주세요."
            return
        }

        let existingAccounts = SiteCredentialStore.accounts(forOrigin: origin)

        var passToSave = passwordInput
        if passToSave.isEmpty {
            guard let prior = SiteCredentialStore.read(origin: origin, username: cleanOld) else {
                noticeMessage = "기존 계정 정보를 읽지 못했습니다."
                return
            }
            passToSave = prior.password
        }
        guard !passToSave.isEmpty else {
            noticeMessage = "비밀번호를 확인할 수 없습니다."
            return
        }

        if cleanOld == cleanNew {
            if SiteCredentialStore.save(origin: origin, username: cleanNew, password: passToSave, replacing: true) {
                if origin == currentOrigin && selectedUsername == cleanOld {
                    selectedUsername = cleanNew
                }
                noticeMessage = "계정 정보를 수정했습니다."
                cancelEditing()
                refreshData()
            } else {
                noticeMessage = "계정 정보 수정에 실패했습니다."
            }
        } else {
            if existingAccounts.contains(cleanNew) {
                noticeMessage = "이미 존재하는 아이디입니다."
                return
            }
            if SiteCredentialStore.replace(origin: origin, oldUsername: cleanOld, username: cleanNew, password: passToSave) {
                if origin == currentOrigin && selectedUsername == cleanOld {
                    selectedUsername = cleanNew
                    usernameInput = cleanNew
                }
                noticeMessage = "계정 정보를 수정했습니다."
                cancelEditing()
                refreshData()
            } else {
                noticeMessage = "계정 정보 수정에 실패했습니다."
            }
        }
    }

    private func performRename() {
        let cleanOld = selectedUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanNew = usernameInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanOld.isEmpty, !cleanNew.isEmpty, cleanOld != cleanNew else {
            noticeMessage = "변경할 새 아이디를 올바르게 입력해 주세요."
            return
        }

        var passToSave = passwordInput
        if passToSave.isEmpty {
            guard let prior = SiteCredentialStore.read(origin: currentOrigin, username: cleanOld) else {
                noticeMessage = "기존 계정 정보를 읽을 수 없습니다."
                return
            }
            passToSave = prior.password
        }
        guard !passToSave.isEmpty else {
            noticeMessage = "비밀번호를 확인할 수 없습니다."
            return
        }

        if SiteCredentialStore.replace(origin: currentOrigin, oldUsername: cleanOld, username: cleanNew, password: passToSave) {
            selectedUsername = cleanNew
            usernameInput = cleanNew
            passwordInput = ""
            noticeMessage = "아이디를 성공적으로 변경했습니다."
            refreshData()
        } else {
            noticeMessage = "아이디 변경에 실패했습니다."
        }
    }

    private func performSave(replacing: Bool) {
        let cleanUser = usernameInput.trimmingCharacters(in: .whitespacesAndNewlines)
        var passToSave = passwordInput
        if passToSave.isEmpty {
            // Retain prior password only after explicit save
            if let prior = SiteCredentialStore.read(origin: currentOrigin, username: cleanUser) {
                passToSave = prior.password
            }
        }
        guard !passToSave.isEmpty else {
            noticeMessage = "비밀번호를 입력해 주세요."
            return
        }

        if SiteCredentialStore.save(origin: currentOrigin, username: cleanUser, password: passToSave, replacing: replacing) {
            selectedUsername = cleanUser
            passwordInput = ""
            noticeMessage = "키체인에 안전하게 저장했습니다."
            refreshData()
        } else {
            noticeMessage = "저장에 실패했습니다."
        }
    }

    private func performDelete(origin: String, username: String) {
        if SiteCredentialStore.delete(origin: origin, username: username) {
            if origin == currentOrigin && username == selectedUsername {
                usernameInput = ""
                passwordInput = ""
                selectedUsername = ""
            }
            refreshData()
            noticeMessage = "삭제했습니다."
        } else {
            noticeMessage = "삭제에 실패했습니다."
        }
    }

    private func performAutofill(origin: String, username: String) {
        guard let wv = model.webView else {
            model.notice = "웹뷰를 찾을 수 없습니다."
            dismiss()
            return
        }

        let capturePopupCommittedURL = model.popupCommittedURL
        let captureGen = model.generation

        let isCurrent: () -> Bool = { [weak model, weak wv] in
            guard let m = model, let wv = wv, let app = m.appModel else { return false }
            guard m.popupCommittedURL == capturePopupCommittedURL else { return false }
            guard app.selectedTab == .browser, app.browser === m, m.webView === wv else { return false }
            guard m.generation == captureGen else { return false }
            return true
        }

        SiteAutofill.fill(
            in: wv,
            origin: origin,
            username: username,
            isCurrent: isCurrent
        ) { msg in
            model.notice = msg
        }
        dismiss()
    }
}
