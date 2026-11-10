import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        List(selection: $state.selectedVolumeID) {
            Section("외장 볼륨") {
                if state.volumes.isEmpty {
                    Text(state.isRefreshing ? "확인 중…" : "연결된 외장 디스크 없음")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                } else {
                    ForEach(state.volumes) { volume in
                        VolumeRow(volume: volume, busy: state.isBusy(volume: volume))
                            .tag(volume.id)
                    }
                }
            }

            if !state.excludedVolumes.isEmpty {
                Section("표시하지 않은 볼륨") {
                    ForEach(state.excludedVolumes) { excluded in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(excluded.name)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Text(excluded.reason)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        .help("외장 디스크처럼 보이지만 조건을 확인하지 못해 목록에서 뺐습니다. 이 앱은 이런 볼륨을 다루지 않습니다.")
                    }
                }
            }

            Section {
                if state.recentOperations.isEmpty {
                    Text("아직 작업 기록이 없습니다")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                } else {
                    ForEach(state.recentOperations.prefix(8)) { op in
                        RecentOperationRow(op: op)
                    }
                }
            } header: {
                HStack {
                    Text("최근 작업")
                    Spacer()
                    if !state.recentOperations.isEmpty {
                        Button("지우기") { state.clearRecent() }
                            .buttonStyle(.plain)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }
}

struct VolumeRow: View {
    let volume: ExternalVolume
    let busy: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "externaldrive.fill")
                .font(.title2)
                .foregroundStyle(Theme.gradient)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(volume.name)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                    if busy {
                        ProgressView().controlSize(.mini)
                    }
                }
                CapacityBar(fraction: volume.usedFraction, height: 5)
                Text("\(ByteFormat.string(volume.totalSize)) 중 \(ByteFormat.string(volume.usedSize)) 사용")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 4)
    }
}

struct RecentOperationRow: View {
    let op: OperationSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Circle()
                    .fill(Theme.color(for: op.outcome))
                    .frame(width: 7, height: 7)
                Text("\(op.kindLabel) · \(op.outcomeLabel)")
                    .font(.caption.weight(.medium))
                Spacer()
                Text(Theme.dateFormatter.string(from: op.date))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text(summaryLine)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(.vertical, 2)
        .help(op.detail)
    }

    private var summaryLine: String {
        switch op.kind {
        case .scan:
            return "\(op.volumeName): 후보 \(op.count)개, \(ByteFormat.string(op.bytes))"
        case .cleanup:
            return "\(op.volumeName): \(op.count)개 삭제, \(ByteFormat.string(op.bytes)) · \(op.detail)"
        case .eject:
            return "\(op.volumeName): \(op.detail)"
        }
    }
}
