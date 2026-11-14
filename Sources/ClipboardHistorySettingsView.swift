import SwiftUI
import AppKit

/// 한툴 환경설정 내 "클립보드" 설정 화면.
public struct ClipboardHistorySettingsView: View {
    @ObservedObject private var store = ClipboardHistoryStore.shared
    @ObservedObject private var shortcut = ClipboardHistoryShortcut.shared
    @ObservedObject private var prefs = ClipboardPanelPreferences.shared
    @ObservedObject private var appearance = HTTAppearanceStore.shared
    @Environment(\.colorScheme) private var systemColorScheme

    @State private var showingClearConfirmation = false
    @State private var showingLimitShrinkWarning = false
    @State private var pendingConfig: ClipboardHistoryConfig?

    public init() {}

    private var palette: HTTThemePalette {
        appearance.palette(for: systemColorScheme)
    }

    public var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 20) {
                // 헤더
                headerSection

                Divider()

                // 단축키 및 접근성 권한 안내
                shortcutAndPermissionSection

                Divider()

                // 테마 및 배경 불투명도 설정
                themeAndAppearanceSection

                Divider()

                // 저장 한도 및 보관 기간 설정
                retentionSettingsSection

                Divider()

                // 현재 사용 통계 및 기록 비우기
                usageAndClearSection

                Spacer(minLength: 20)
            }
            .padding(24)
            .frame(maxWidth: 680, alignment: .leading)
        }
        .background(palette.bg)
        .alert("클립보드를 모두 삭제하시겠습니까?", isPresented: $showingClearConfirmation) {
            Button("취소", role: .cancel) {}
            Button("모두 삭제", role: .destructive) {
                store.clearAllHistory()
            }
        } message: {
            Text("한툴에 저장된 텍스트 및 이미지 기록이 영구적으로 삭제됩니다. 시스템의 현재 클립보드 내용은 보존됩니다.")
        }
        .alert("보관 한도 축소 안내", isPresented: $showingLimitShrinkWarning) {
            Button("취소", role: .cancel) {
                pendingConfig = nil
            }
            Button("적용", role: .destructive) {
                if let cfg = pendingConfig {
                    store.config = cfg
                }
                pendingConfig = nil
            }
        } message: {
            Text("보관 한도를 줄이면 한도를 초과하는 오래된 기록(텍스트 및 이미지)이 자동으로 정리될 수 있습니다. 계속 진행하시겠습니까?")
        }
    }

    // MARK: - Header
    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("클립보드")
                .font(.title2.weight(.bold))
                .foregroundColor(palette.text)

            Text("복사한 텍스트와 이미지를 로컬에 안전하게 보관하고, 언제든 다시 찾아 붙여넣을 수 있습니다.")
                .font(.subheadline)
                .foregroundColor(palette.muted)
        }
    }

    // MARK: - Shortcut & Permission
    private var shortcutAndPermissionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("호출 단축키 및 권한")
                .font(.headline)
                .foregroundColor(palette.text)

            HStack(spacing: 12) {
                Image(systemName: "keyboard")
                    .font(.title3)
                    .foregroundColor(palette.accent)

                VStack(alignment: .leading, spacing: 2) {
                    Text("단축키: ⇧ Shift 누른 채 + ⌘ Command 연속 2회 탭")
                        .font(.body.weight(.medium))
                        .foregroundColor(palette.text)
                    Text("마우스 클릭이나 다른 일반 키가 섞이지 않도록 순수하게 보조키만 탭하세요.")
                        .font(.caption)
                        .foregroundColor(palette.muted)
                }

                Spacer()

                Button("지금 열기") {
                    ClipboardHistoryPanelController.shared.showAndFocus()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .padding(12)
            .background(palette.card)
            .cornerRadius(8)

            // 손쉬운 사용 권한 상태
            HStack(spacing: 12) {
                Image(systemName: shortcut.isAccessibilityTrusted ? "checkmark.shield.fill" : "exclamationmark.triangle.fill")
                    .foregroundColor(shortcut.isAccessibilityTrusted ? .green : .orange)

                VStack(alignment: .leading, spacing: 2) {
                    Text(shortcut.isAccessibilityTrusted ? "손쉬운 사용 권한 부여됨" : "손쉬운 사용 권한 필요")
                        .font(.subheadline.weight(.medium))
                        .foregroundColor(palette.text)
                    Text(shortcut.isAccessibilityTrusted ? "전역 보조키 탭 단축키가 원활히 동작합니다." : "권한이 없으면 전역 단축키 인식이 제한될 수 있습니다. 메뉴 막대 아이콘에서도 언제든 열 수 있습니다.")
                        .font(.caption)
                        .foregroundColor(palette.muted)
                }

                Spacer()

                if !shortcut.isAccessibilityTrusted {
                    Button("시스템 설정 열기") {
                        openAccessibilityPreferences()
                    }
                    .controlSize(.small)
                }
            }
            .padding(12)
            .background(palette.card)
            .cornerRadius(8)
        }
    }

    // MARK: - Theme & Appearance
    private var themeAndAppearanceSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("테마 및 화면 표시")
                .font(.headline)
                .foregroundColor(palette.text)

            // 테마 스타일 선택
            VStack(alignment: .leading, spacing: 8) {
                Text("배경 테마")
                    .font(.subheadline)
                    .foregroundColor(palette.text)

                Picker("", selection: $prefs.useCustomColor) {
                    Text("기본 앱 테마").tag(false)
                    Text("사용자 지정 색상").tag(true)
                }
                .pickerStyle(.segmented)

                if prefs.useCustomColor {
                    HStack {
                        Text("사용자 지정 색상 선택")
                            .font(.subheadline)
                            .foregroundColor(palette.text)
                        Spacer()
                        ColorPicker("", selection: Binding<Color>(
                            get: { color(from: prefs.customColorHex) },
                            set: { newColor in
                                prefs.customColorHex = hexString(from: newColor)
                            }
                        ), supportsOpacity: false)
                        .labelsHidden()
                    }
                    .padding(.top, 4)
                }
            }

            // 불투명도 슬라이더 (10% ~ 100%)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("배경 불투명도")
                        .font(.subheadline)
                        .foregroundColor(palette.text)
                    Spacer()
                    Text("\(Int(round(prefs.opacity * 100)))%")
                        .font(.subheadline.monospacedDigit())
                        .foregroundColor(palette.muted)
                }
                Slider(
                    value: $prefs.opacity,
                    in: 0.1...1.0,
                    step: 0.05
                )
            }
        }
        .padding(14)
        .background(palette.card)
        .cornerRadius(8)
    }

    // MARK: - Retention Settings
    private var retentionSettingsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("보관 정책 및 한도")
                .font(.headline)
                .foregroundColor(palette.text)

            // 1. 텍스트 최대 보관 개수
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("텍스트 최대 보관 수")
                        .font(.subheadline)
                        .foregroundColor(palette.text)
                    Spacer()
                    Text("\(store.config.maxTextCount)개")
                        .font(.subheadline.monospacedDigit())
                        .foregroundColor(palette.muted)
                }
                Picker("", selection: Binding<Int>(
                    get: { store.config.maxTextCount },
                    set: { newVal in
                        checkAndApplyConfigChange { cfg in
                            cfg.maxTextCount = newVal
                        }
                    }
                )) {
                    Text("50개").tag(50)
                    Text("100개 (기본)").tag(100)
                    Text("200개").tag(200)
                    Text("500개").tag(500)
                    Text("1,000개").tag(1000)
                }
                .pickerStyle(.segmented)
            }

            // 2. 이미지 최대 보관 개수
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("이미지 최대 보관 수")
                        .font(.subheadline)
                        .foregroundColor(palette.text)
                    Spacer()
                    Text("\(store.config.maxImageCount)개")
                        .font(.subheadline.monospacedDigit())
                        .foregroundColor(palette.muted)
                }
                Picker("", selection: Binding<Int>(
                    get: { store.config.maxImageCount },
                    set: { newVal in
                        checkAndApplyConfigChange { cfg in
                            cfg.maxImageCount = newVal
                        }
                    }
                )) {
                    Text("20개").tag(20)
                    Text("50개 (기본)").tag(50)
                    Text("100개").tag(100)
                    Text("200개").tag(200)
                }
                .pickerStyle(.segmented)
            }

            // 3. 보관 기간
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("보관 기간")
                        .font(.subheadline)
                        .foregroundColor(palette.text)
                    Spacer()
                    Text(retentionPeriodString(store.config.retentionDays))
                        .font(.subheadline)
                        .foregroundColor(palette.muted)
                }
                Picker("", selection: Binding<Int>(
                    get: { store.config.retentionDays },
                    set: { newVal in
                        checkAndApplyConfigChange { cfg in
                            cfg.retentionDays = newVal
                        }
                    }
                )) {
                    Text("7일").tag(7)
                    Text("14일").tag(14)
                    Text("30일 (기본)").tag(30)
                    Text("90일").tag(90)
                    Text("영구 보관").tag(0)
                }
                .pickerStyle(.segmented)
            }

            // 4. 최대 디스크 사용량
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("최대 디스크 용량 (이미지 캐시)")
                        .font(.subheadline)
                        .foregroundColor(palette.text)
                    Spacer()
                    Text("\(store.config.maxDiskUsageMB) MB")
                        .font(.subheadline.monospacedDigit())
                        .foregroundColor(palette.muted)
                }
                Picker("", selection: Binding<Int>(
                    get: { store.config.maxDiskUsageMB },
                    set: { newVal in
                        checkAndApplyConfigChange { cfg in
                            cfg.maxDiskUsageMB = newVal
                        }
                    }
                )) {
                    Text("200 MB").tag(200)
                    Text("500 MB (기본)").tag(500)
                    Text("1 GB").tag(1000)
                    Text("2 GB").tag(2000)
                }
                .pickerStyle(.segmented)
            }
        }
        .padding(14)
        .background(palette.card)
        .cornerRadius(8)
    }

    // MARK: - Usage & Clear History
    private var usageAndClearSection: some View {
        let totalItems = store.items.count
        let textCount = store.items.filter { $0.type == .text }.count
        let imageCount = store.items.filter { $0.type == .image }.count
        let totalDiskBytes = store.items.compactMap { $0.fileSize }.reduce(0, +)
        let diskFormatted = ByteCountFormatter.string(fromByteCount: totalDiskBytes, countStyle: .file)

        return VStack(alignment: .leading, spacing: 12) {
            Text("저장 상태 및 관리")
                .font(.headline)
                .foregroundColor(palette.text)

            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("현재 저장 항목: 총 \(totalItems)개 (텍스트 \(textCount)개, 이미지 \(imageCount)개)")
                        .font(.subheadline)
                        .foregroundColor(palette.text)
                    Text("이미지 저장소 사용량: \(diskFormatted) (경로: ~/Library/Application Support/HanTool/ClipboardImages)")
                        .font(.caption)
                        .foregroundColor(palette.muted)
                }

                Spacer()

                Button("기록 모두 지우기", role: .destructive) {
                    showingClearConfirmation = true
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(12)
            .background(palette.card)
            .cornerRadius(8)
        }
    }

    // MARK: - Helpers
    private func checkAndApplyConfigChange(mutator: (inout ClipboardHistoryConfig) -> Void) {
        var updated = store.config
        let original = store.config
        mutator(&updated)

        // 한도 축소 여부 확인
        let isShrinking = updated.maxTextCount < original.maxTextCount
            || updated.maxImageCount < original.maxImageCount
            || (original.retentionDays == 0 && updated.retentionDays > 0)
            || (original.retentionDays > 0 && updated.retentionDays > 0 && updated.retentionDays < original.retentionDays)
            || updated.maxDiskUsageMB < original.maxDiskUsageMB

        if isShrinking {
            pendingConfig = updated
            showingLimitShrinkWarning = true
        } else {
            store.config = updated
        }
    }

    private func retentionPeriodString(_ days: Int) -> String {
        if days == 0 { return "영구 보관" }
        return "\(days)일"
    }

    private func openAccessibilityPreferences() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private func hexString(from color: Color) -> String {
        if let nsColor = NSColor(color).usingColorSpace(.sRGB) {
            let r = Int(round(nsColor.redComponent * 255))
            let g = Int(round(nsColor.greenComponent * 255))
            let b = Int(round(nsColor.blueComponent * 255))
            return String(format: "#%02X%02X%02X", r, g, b)
        }
        return "#000000"
    }

    private func color(from hex: String) -> Color {
        let cleanHex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        guard !cleanHex.isEmpty else { return palette.bg }
        var int: UInt64 = 0
        guard Scanner(string: cleanHex).scanHexInt64(&int) else { return palette.bg }
        let r, g, b: Double
        switch cleanHex.count {
        case 6:
            r = Double((int >> 16) & 0xFF) / 255.0
            g = Double((int >> 8) & 0xFF) / 255.0
            b = Double(int & 0xFF) / 255.0
            return Color(.sRGB, red: r, green: g, blue: b, opacity: 1.0)
        default:
            return palette.bg
        }
    }
}
