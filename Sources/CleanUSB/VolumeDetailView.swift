import SwiftUI
import HTTThemeCore

struct VolumeDetailView: View {
    @EnvironmentObject private var state: AppState
    let volume: ExternalVolume

    private var scan: ScanResult? { state.scanResult(for: volume) }
    private var busyHere: Bool { state.isBusy(volume: volume) }
    private var selectedCount: Int { state.selectedIDs(for: volume).count }
    private var selectedBytes: Int64 { state.selectedCandidates(for: volume).reduce(0) { $0 + $1.size } }
    /// 확인 결과가 볼륨 전체를 다루지 못한 경우(취소·잘림·접근 거부·깊이 제한·오류) '정리 후 추출'을 막는다.
    private var canChainEject: Bool {
        guard let scan else { return false }
        return scan.isComplete
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if let message = state.message(for: volume) {
                    StatusBanner(message: message)
                }
                optionsCard
                actionsCard
                if busyHere {
                    progressCard
                }
                let failures = state.failures(for: volume)
                if !failures.isEmpty {
                    FailureListView(failures: failures)
                }
                if let scan {
                    CandidateListView(volume: volume, scan: scan)
                }
            }
            .padding(20)
        }
        .background(.httPaper)
        .navigationTitle(volume.name)
        .navigationSubtitle(volume.mountPath)
    }

    // MARK: - 구역

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Theme.gradient)
                    .frame(width: 56, height: 56)
                Image(systemName: "externaldrive.fill")
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(volume.name)
                    .font(.title.weight(.semibold))
                Text(detailLine)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                CapacityBar(fraction: volume.usedFraction, height: 8)
                    .padding(.top, 4)
                HStack {
                    Text("사용 \(ByteFormat.string(volume.usedSize))")
                    Spacer()
                    Text("여유 \(ByteFormat.string(volume.freeSpace))")
                    Spacer()
                    Text("전체 \(ByteFormat.string(volume.totalSize))")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .card()
    }

    private var detailLine: String {
        var parts = [volume.filesystemName]
        if !volume.busProtocol.isEmpty { parts.append(volume.busProtocol) }
        parts.append(volume.deviceIdentifier)
        parts.append(volume.mountPath)
        return parts.joined(separator: " · ")
    }

    private var optionsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("정리 대상")
                .font(.headline)
            HStack(alignment: .top, spacing: 24) {
                targetLabel(".DS_Store", CleanupKind.dsStore.description, on: true)
                targetLabel("Thumbs.db", CleanupKind.thumbsDb.description, on: true)
            }
            Divider()
            Toggle(isOn: $state.includeAppleDouble) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("._ 부속 파일(AppleDouble)도 포함")
                        .font(.body.weight(.medium))
                    Text("기본은 꺼짐입니다. 이 파일에는 원본 파일의 리소스 포크, Finder 태그, 확장 속성이 들어 있을 수 있어 삭제하면 그 정보가 사라집니다. 필요할 때만 켜세요. 이 옵션을 바꾸면 모든 볼륨의 확인 결과가 지워지므로 '정리할 파일 확인'을 다시 실행해야 합니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
            .disabled(state.isBusy)
            if let scan {
                Text(scan.options.includeAppleDouble
                     ? "아래 목록은 ._ 부속 파일을 포함해 확인한 결과입니다."
                     : "아래 목록은 .DS_Store와 Thumbs.db만 확인한 결과입니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("위 이름과 정확히 일치하는 일반 파일만 지웁니다. 폴더, 링크, .Trashes·Spotlight·fseventsd 같은 시스템 폴더 안의 항목은 건드리지 않습니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .card()
    }

    private func targetLabel(_ name: String, _ desc: String, on: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.body.weight(.medium)).monospaced()
                Text(desc).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var actionsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                if busyHere {
                    Button(role: .cancel) {
                        state.cancelCurrentOperation()
                    } label: {
                        Label("취소", systemImage: "xmark.circle")
                    }
                    .disabled(state.phase == .ejecting)
                } else {
                    Button {
                        state.startScan(volume)
                    } label: {
                        Label(scan == nil ? "정리할 파일 확인" : "다시 확인", systemImage: "magnifyingglass")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(state.isBusy)
                }

                if scan != nil {
                    Button {
                        state.requestCleanup(volume, thenEject: false)
                    } label: {
                        Label("선택 정리 (\(selectedCount)개)", systemImage: "trash")
                    }
                    .disabled(state.isBusy || selectedCount == 0)
                    .help("선택한 파일만 삭제합니다. 실행 전에 한 번 더 확인합니다.")

                    Button {
                        state.requestCleanup(volume, thenEject: true)
                    } label: {
                        Label("정리 후 추출", systemImage: "eject")
                    }
                    .disabled(state.isBusy || selectedCount == 0 || !canChainEject)
                    .help(canChainEject
                          ? "선택한 파일을 모두 삭제한 뒤 문제가 없으면 추출합니다."
                          : "확인이 볼륨 전체를 다루지 못해(취소·잘림·접근 거부·깊이 제한·오류) 정리 후 자동 추출을 할 수 없습니다. 정리 후 '추출' 버튼을 직접 누르세요.")
                }

                Spacer()

                Button {
                    state.performEject(volume)
                } label: {
                    Label("추출", systemImage: "eject.fill")
                }
                .disabled(state.isBusy)
                .help("정리와 관계없이 지금 바로 추출합니다. 강제 추출은 하지 않습니다.")
            }
            .controlSize(.large)

            if scan == nil && !busyHere {
                Text("검사는 자동으로 시작되지 않습니다. '정리할 파일 확인'을 누르면 이 볼륨만 백그라운드에서 읽어 정리 후보를 보여 줍니다. 이 단계에서는 아무것도 삭제하지 않습니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if scan != nil {
                Text("선택 \(selectedCount)개 · \(ByteFormat.string(selectedBytes))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .card()
    }

    private var progressCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch state.phase {
            case .scanning:
                HStack {
                    ProgressView().controlSize(.small)
                    Text("확인 중… 폴더 \(state.scanProgress.directoriesVisited)개 확인, 후보 \(state.scanProgress.found)개 발견")
                        .font(.callout)
                }
                Text(state.scanProgress.currentDirectory.isEmpty ? "/" : "/" + state.scanProgress.currentDirectory)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            case .cleaning:
                let p = state.cleanupProgress
                ProgressView(value: Double(p.done), total: Double(max(1, p.total))) {
                    Text("정리 중… \(p.done) / \(p.total)")
                        .font(.callout)
                }
            case .ejecting:
                HStack {
                    ProgressView().controlSize(.small)
                    Text("추출 중…").font(.callout)
                }
            case .idle:
                EmptyView()
            }
        }
        .card()
    }
}

struct StatusBanner: View {
    let message: StatusMessage

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: Theme.symbol(for: message.level))
                .foregroundStyle(Theme.color(for: message.level))
                .font(.title3)
            Text(message.text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous)
                .fill(Theme.color(for: message.level).opacity(0.10))
        )
    }
}

struct FailureListView: View {
    let failures: [FileFailure]
    @State private var expanded = true

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(failures.prefix(200)) { f in
                    HStack(alignment: .top, spacing: 8) {
                        Text(f.relativePath)
                            .font(.caption.monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(f.message)
                            .font(.caption)
                            .foregroundStyle(.httDanger)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if failures.count > 200 {
                    Text("외 \(failures.count - 200)개").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.top, 6)
        } label: {
            Label("실패한 항목 \(failures.count)개", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.httWarn)
        }
        .card()
    }
}
