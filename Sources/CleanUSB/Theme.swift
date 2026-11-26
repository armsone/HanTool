import SwiftUI
import HTTThemeCore

/// USB 정리 화면의 색·간격.
enum Theme {
    /// 강조색은 공용 팔레트를 따른다.
    static let accent = HTTStyle(.accent)
    static let gradient = HTTStyle(.accent)
    static let cardCorner: CGFloat = 12

    static func color(for level: StatusMessage.Level) -> HTTStyle {
        switch level {
        case .info: return accent
        case .success: return HTTStyle(.success)
        case .warning: return HTTStyle(.warn)
        case .error: return HTTStyle(.danger)
        }
    }

    static func symbol(for level: StatusMessage.Level) -> String {
        switch level {
        case .info: return "info.circle.fill"
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }

    static func color(for outcome: OperationSummary.Outcome) -> HTTStyle {
        switch outcome {
        case .success: return HTTStyle(.success)
        case .partial: return HTTStyle(.warn)
        case .failed: return HTTStyle(.danger)
        case .cancelled: return HTTStyle(.muted)
        }
    }

    static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.dateFormat = "M월 d일 HH:mm"
        return f
    }()
}

/// 흰 배경 카드. 상세 화면의 각 구역을 감싼다.
struct CardBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous)
                    .fill(.httCard)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06))
            )
    }
}

extension View {
    func card() -> some View { modifier(CardBackground()) }
}

/// 사용량 막대. 사이드바와 상세 헤더에서 같은 모양으로 쓴다.
struct CapacityBar: View {
    let fraction: Double
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(Theme.gradient)
                    .frame(width: max(height, geo.size.width * fraction))
            }
        }
        .frame(height: height)
    }
}
