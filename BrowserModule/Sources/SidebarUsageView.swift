import SwiftUI

/// 기존 사용량 수집기(CCMB)가 발행한 남은 사용량(%) 5칸. 값이 없으면 nil(표시는 "—").
/// 순서: Codex 주간, Claude 세션, Gemini 1, Gemini 2, Gemini 3.
@MainActor
public final class SidebarUsageStore: ObservableObject {
    public static let shared = SidebarUsageStore()
    @Published public private(set) var remaining: [Double?] = [nil, nil, nil, nil, nil]

    public func update(_ values: [Double?]) {
        guard values.count == 5 else { return }
        if values != remaining { remaining = values }
    }
}

private let sidebarUsageRows: [(full: String, short: String)] = [
    ("Codex 주간", "CX"),
    ("Claude 세션", "CL"),
    ("Gemini 1", "G1"),
    ("Gemini 2", "G2"),
    ("Gemini 3", "G3")
]

private func sidebarUsagePercentText(_ value: Double?) -> String {
    guard let value else { return "—" }
    let tenths = (min(max(value, 0), 100) * 10).rounded() / 10
    return tenths == tenths.rounded() ? "\(Int(tenths))%" : "\(tenths)%"
}

/// 얇은(3pt) 진행 막대: 은은한 트랙 + 현재 테마 accent 채움.
private struct SidebarUsageBar: View {
    let fraction: Double
    @Environment(\.bkPalette) private var palette

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(palette.borderColor.opacity(0.45))
                Capsule()
                    .fill(palette.accentColor)
                    .frame(width: geo.size.width * CGFloat(min(max(fraction, 0), 1)))
            }
        }
        .frame(height: 3)
        .accessibilityHidden(true)
    }
}

/// 펼친 사이드바: "남은 사용량" 접이식 제목 + 5행(라벨 / 진행 막대 / 남은 %).
struct SidebarUsageSection: View {
    @ObservedObject private var store = SidebarUsageStore.shared
    @Environment(\.bkPalette) private var palette
    @State private var isExpanded = true

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            Button {
                isExpanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    Text("남은 사용량")
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .regular))
                        .foregroundColor(palette.mutedColor)
                        .frame(width: 10)
                }
                .font(.system(size: 12, weight: .regular))
                .foregroundColor(palette.textColor)
                .padding(.horizontal, 10)
                .frame(height: 26)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("남은 사용량 \(isExpanded ? "접기" : "펼치기")")
            if isExpanded {
                VStack(spacing: 0) {
                    ForEach(0..<sidebarUsageRows.count, id: \.self) { index in
                        let value = store.remaining[index]
                        HStack(spacing: 6) {
                            Text(sidebarUsageRows[index].full)
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                                .frame(width: 66, alignment: .leading)
                            SidebarUsageBar(fraction: min(max(value ?? 0, 0), 100) / 100)
                            Text(sidebarUsagePercentText(value))
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                                .monospacedDigit()
                                .frame(width: 34, alignment: .trailing)
                        }
                        .frame(height: 17)
                        .font(.system(size: 11, weight: .regular))
                        .foregroundColor(palette.textColor)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(sidebarUsageRows[index].full) 남은 사용량")
                        .accessibilityValue(value == nil ? "정보 없음" : sidebarUsagePercentText(value))
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
            }
        }
    }
}

/// 접힌 레일: 5행 압축 표시. 각 행은 라벨+% 한 줄. 기본 닫힘, 같은 자리의 화살표 버튼으로 열고 닫으며 상태는 저장.
struct SidebarUsageCompact: View {
    @ObservedObject private var store = SidebarUsageStore.shared
    @Environment(\.bkPalette) private var palette
    @AppStorage("SidebarUsageCompactExpanded", store: HTDBrowserDefaults.standard) private var isExpanded = false

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            Button {
                isExpanded.toggle()
            } label: {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.up")
                    .font(.system(size: 9, weight: .regular))
                    .foregroundColor(palette.mutedColor)
                    .frame(maxWidth: .infinity)
                    .frame(height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isExpanded ? "남은 사용량 숨기기" : "남은 사용량 보기")
            .accessibilityLabel(isExpanded ? "남은 사용량 숨기기" : "남은 사용량 보기")
            .accessibilityHint("CX, CL, G1, G2, G3 남은 사용량 표시를 \(isExpanded ? "닫습니다" : "엽니다")")
            if isExpanded {
                VStack(spacing: 2) {
                    ForEach(0..<sidebarUsageRows.count, id: \.self) { index in
                        HStack(spacing: 4) {
                            Text(sidebarUsageRows[index].short)
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                                .frame(width: 18, alignment: .leading)
                            Text(sidebarUsagePercentText(store.remaining[index]))
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                                .monospacedDigit()
                                .frame(width: 30, alignment: .trailing)
                        }
                            .font(.system(size: 9, weight: .regular))
                            .foregroundColor(palette.textColor)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("\(sidebarUsageRows[index].full) 남은 사용량 \(store.remaining[index] == nil ? "정보 없음" : sidebarUsagePercentText(store.remaining[index]))")
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.bottom, 6)
            }
        }
    }
}
