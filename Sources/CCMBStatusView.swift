import AppKit
import HTTCCMB
import SwiftUI

public struct CCMBStatusView: View {
    @ObservedObject private var integration = CCMBIntegration.shared
    private let onOpenSettings: () -> Void

    public init(onOpenSettings: @escaping () -> Void) {
        self.onOpenSettings = onOpenSettings
    }

    public var body: some View {
        VStack(spacing: 0) {
            headerView
            Divider()
            contentView
        }
        .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var headerView: some View {
        HStack(alignment: .center, spacing: 8) {
            Text("서버 현황")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.primary)

            Spacer()

            if !integration.isEnabled {
                Text("꺼짐")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.12))
                    .cornerRadius(4)
            } else if isNASUnconfigured {
                Text("놀이터(NAS) · 주소 미설정")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.12))
                    .cornerRadius(4)
            } else {
                HStack(spacing: 4) {
                    Text(sourceTitle)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                    if let statusText = connectionStatusText {
                        Text("· \(statusText)")
                            .font(.system(size: 11, weight: .regular))
                            .foregroundColor(connectionStatusColor)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.secondary.opacity(0.10))
                .cornerRadius(4)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var isNASUnconfigured: Bool {
        integration.dataSource == CCMBIntegration.sourceNAS &&
        integration.serverTarget.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var sourceTitle: String {
        if integration.dataSource == CCMBIntegration.sourceNAS {
            return "놀이터(NAS)"
        } else if integration.dataSource == CCMBIntegration.sourceLocalMac {
            return "로컬 Mac"
        }
        return integration.dataSource
    }

    private var connectionStatusText: String? {
        guard integration.dataSource == CCMBIntegration.sourceNAS else { return nil }
        switch integration.connectionState {
        case .idle:
            return nil
        case .checking:
            return "연결 확인 중"
        case .connected(let authenticated, _):
            return authenticated ? "연결됨" : "인증 필요"
        case .failed(let message):
            return "연결 실패: \(message)"
        }
    }

    private var connectionStatusColor: Color {
        switch integration.connectionState {
        case .idle, .checking:
            return .secondary
        case .connected(let authenticated, _):
            return authenticated ? .green : .orange
        case .failed:
            return .red
        }
    }

    @ViewBuilder
    private var contentView: some View {
        if !integration.isEnabled {
            VStack(spacing: 12) {
                Spacer()
                Image(systemName: "server.rack")
                    .font(.system(size: 32))
                    .foregroundColor(.secondary)
                Text("서버 현황 모니터링이 꺼져 있습니다.")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.secondary)
                Button("서버 현황 설정") {
                    onOpenSettings()
                }
                .controlSize(.regular)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(24)
        } else if isNASUnconfigured {
            VStack(spacing: 12) {
                Spacer()
                Image(systemName: "network.slash")
                    .font(.system(size: 32))
                    .foregroundColor(.secondary)
                Text("놀이터(NAS) 대상 서버 주소가 설정되지 않았습니다.")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.secondary)
                Button("서버 현황 설정") {
                    onOpenSettings()
                }
                .controlSize(.regular)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(24)
        } else {
            ScrollView([.horizontal, .vertical]) {
                InlineStatusRepresentable()
                    .id("\(integration.isEnabled)-\(integration.dataSource)-\(integration.serverTarget)-\(integration.runtimeGeneration)")
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
    }
}

private struct InlineStatusRepresentable: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        if let statusView = HTTCCMBRuntime.makeInlineStatusView() {
            return statusView
        }
        let fallback = NSTextField(labelWithString: "아직 확인되지 않음/갱신 중")
        fallback.font = .systemFont(ofSize: 13, weight: .medium)
        fallback.alignment = .center
        fallback.textColor = .secondaryLabelColor
        return fallback
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Updates are triggered through AppDelegate updateSplitPanel notifications.
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView, context: Context) -> CGSize? {
        let size = nsView.intrinsicContentSize
        let width = size.width > 0 ? size.width : (proposal.width ?? 320)
        let height = size.height > 0 ? size.height : (proposal.height ?? 120)
        return CGSize(width: width, height: height)
    }
}
