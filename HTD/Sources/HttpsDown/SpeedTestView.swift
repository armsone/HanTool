import SwiftUI

/// '속도 측정' sheet (opened from the header). The measurement is started by the header button; closing the sheet
/// cancels a measurement still running. Unknown values are shown as unknown, never as 0.
struct SpeedTestView: View {
    @ObservedObject var appModel: AppModel
    @ObservedObject var connection: ConnectionManager
    let close: () -> Void
    @Environment(\.bkPalette) var palette

    private var state: SpeedTestState { appModel.speedTest }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Label {
                    Text("인터넷 속도 간이 측정")
                } icon: {
                    Image(systemName: "speedometer").foregroundColor(palette.accentColor)
                }
                .font(.headline)
                Spacer()
                Text("실효 측정")
                    .font(.caption2.bold())
                    .foregroundColor(palette.text2Color)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(palette.surface2Color))
                    .help("이 앱의 현재 연결 경로로 실제 데이터를 주고받은 결과입니다. 통신사 최대 속도를 보장하는 값이 아닙니다.")
            }

            VStack(alignment: .leading, spacing: 4) {
                infoRow("측정 서버", "Cloudflare (\(ConnectionManager.speedTestHost))")
                infoRow("연결 방식", modeText)
                infoRow("데이터 사용", usageText)
            }

            HStack(spacing: 8) {
                if state.isRunning {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: phaseIcon).foregroundColor(phaseColor)
                }
                Text(phaseText)
                    .font(.callout)
                    .lineLimit(2)
                Spacer(minLength: 0)
                if state.isRunning, let live = state.liveMbps {
                    let formatted = formatSpeed(mbps: live)
                    Text("현재 \(formatted.value) \(formatted.unit)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .help("지금 주고받는 중인 요청의 순간 값입니다 (최종 결과 아님).")
                }
            }

            HStack(spacing: 10) {
                let dl = state.downloadMbps.map { formatSpeed(mbps: $0) }
                metricTile("다운로드", value: dl?.value, unit: dl?.unit ?? "MB/s",
                           active: state.phase == .download, note: state.downloadPartial ? "일부 구간" : nil,
                           help: "응답 헤더를 받은 뒤 본문을 다 받을 때까지 실제로 받은 바이트로 계산했습니다 (연결 수립·요청 왕복 제외).")
                let ul = state.uploadMbps.map { formatSpeed(mbps: $0) }
                metricTile("업로드", value: ul?.value, unit: ul?.unit ?? "MB/s",
                           active: state.phase == .upload, note: nil,
                           help: "더미 데이터를 보내기 시작한 때부터 서버 응답을 받을 때까지로 계산한 실효 값입니다 (응답 왕복 1회 포함). 사용자 파일은 보내지 않습니다.")
                metricTile("HTTP 응답", value: state.latencyMs.map { String(format: "%.0f", $0) }, unit: "ms",
                           active: state.phase == .latency || state.phase == .connect,
                           note: state.latencySamples > 0 ? "중앙값 \(state.latencySamples)회" : nil,
                           help: "빈 HTTP 요청을 여러 번 보내 응답 헤더가 올 때까지 걸린 시간의 중앙값입니다. ICMP ping이 아닙니다.")
            }

            if let failure = state.failure, !failure.isEmpty {
                Text(failure)
                    .font(.caption)
                    .foregroundColor(state.phase == .finished ? palette.warnColor : palette.dangerColor)
                    .lineLimit(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(failure)
            }

            Text("간이 측정입니다. 통신사 최대 속도나 다른 앱의 속도를 보장하지 않고, 응답 시간은 ICMP ping이 아닙니다. 측정하는 동안 대기열의 작업은 잠시 기다리고 연결 방식은 바꿀 수 없습니다. Cloudflare는 일반적인 접속 정보(IP 주소 등)를 볼 수 있으며, 쿠키·로그인 정보·사용자 파일은 보내지 않습니다.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                if state.isRunning {
                    Button("측정 취소") { appModel.cancelSpeedTest() }
                        .keyboardShortcut(.cancelAction)
                        .accessibilityLabel("속도 측정 취소")
                } else {
                    let runLabel = state.phase == .idle ? "측정 시작" : "다시 측정"
                    Button(runLabel) { appModel.startSpeedTest() }
                        .disabled(appModel.isMeasuringSpeed)
                        .accessibilityLabel(state.phase == .idle ? "속도 측정 시작" : "속도 다시 측정")
                }
                Button("닫기") { close() }
                    .keyboardShortcut(.defaultAction)
                    .help(state.isRunning ? "닫으면 진행 중인 측정을 취소합니다." : "창을 닫습니다.")
            }
        }
        .padding(18)
        .frame(width: 460)
        .background(palette.cardColor)
        .onDisappear { appModel.cancelSpeedTest() }   // closing never leaves a measurement running
    }

    private var modeText: String {
        let helper = state.phase == .idle ? connection.enabled : state.viaHelper
        return helper ? "HTTPS 연결 도움 경유 (앱 전용 경로, 첫 TLS 메시지 나눠 보내기)" : "시스템 기본 연결 (직접)"
    }

    private var usageText: String {
        let used = String(format: "%.1f", Double(state.bytesUsed) / 1_048_576.0)
        let tail = state.seconds.map { String(format: ", %.0f초 걸림", $0) } ?? ""
        return "\(used)MB 사용\(tail) · 최대 약 \(SpeedTestState.byteCapMiB)MB, \(SpeedTestState.durationHint)"
    }

    /// Formats an internal Mbps rate into decimal byte units (KB/s or MB/s).
    /// 1 Mbps = 125,000 bytes/sec. Uses MB/s for >= 1e6 bytes/sec, KB/s below.
    private func formatSpeed(mbps: Double) -> (value: String, unit: String) {
        guard !mbps.isNaN, !mbps.isInfinite else {
            return (value: "알 수 없음", unit: "")
        }
        let bytesPerSec = mbps * 125_000.0
        if bytesPerSec >= 1_000_000.0 {
            let mbPerSec = bytesPerSec / 1_000_000.0
            return (value: String(format: "%.1f", mbPerSec), unit: "MB/s")
        } else {
            let kbPerSec = bytesPerSec / 1_000.0
            return (value: String(format: "%.1f", kbPerSec), unit: "KB/s")
        }
    }

    private var phaseText: String {
        switch state.phase {
        case .idle: return "'측정 시작'을 누르면 측정을 시작합니다."
        default: return state.message.isEmpty ? state.phase.rawValue : state.message
        }
    }

    private var phaseIcon: String {
        switch state.phase {
        case .finished: return state.failure == nil ? "checkmark.circle.fill" : "exclamationmark.circle.fill"
        case .failed, .unavailable: return "exclamationmark.triangle.fill"
        case .cancelled: return "xmark.circle"
        default: return "speedometer"
        }
    }

    private var phaseColor: Color {
        switch state.phase {
        case .finished: return state.failure == nil ? .green : palette.warnColor
        case .failed, .unavailable: return palette.warnColor
        default: return palette.mutedColor
        }
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .leading)
            Text(value)
                .font(.caption)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Value or an honest placeholder: "측정 중" while that phase runs, "—" before it, "알 수 없음" when it ended
    /// without a value.
    private func metricTile(_ title: String, value: String?, unit: String, active: Bool, note: String?,
                            help: String) -> some View {
        let placeholder: String
        if active && state.isRunning {
            placeholder = "측정 중"
        } else if state.isRunning || state.phase == .idle {
            placeholder = "—"
        } else {
            placeholder = "알 수 없음"
        }
        return VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            if let value = value {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(value).font(.title2.monospacedDigit().bold())
                    Text(unit).font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text(placeholder).font(.title3).foregroundStyle(.secondary)
            }
            Text(note ?? " ").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8)
            .fill(active && state.isRunning ? palette.accentSoftColor : palette.surfaceColor))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .stroke(active && state.isRunning ? palette.accentColor : palette.borderColor, lineWidth: 1))
        .help(help)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title) \(value.map { "\($0) \(unit)" } ?? placeholder)")
    }
}
