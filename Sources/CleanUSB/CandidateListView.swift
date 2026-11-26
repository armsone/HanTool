import SwiftUI
import HTTThemeCore

/// 확인 결과 목록. 각 항목을 개별 선택할 수 있고 종류별 필터·경로 검색·전체 선택·해제를 제공한다.
struct CandidateListView: View {
    @EnvironmentObject private var state: AppState
    let volume: ExternalVolume
    let scan: ScanResult

    @State private var filter: CleanupKind?
    @State private var searchText = ""

    private var visible: [USBCleanupCandidate] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        return scan.candidates.filter { candidate in
            (filter == nil || candidate.kind == filter)
                && (query.isEmpty || candidate.relativePath.localizedCaseInsensitiveContains(query))
        }
    }

    private var selectedIDs: Set<String> { state.selectedIDs(for: volume) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("정리 후보 \(scan.candidates.count)개 · \(ByteFormat.string(scan.totalBytes))")
                        .font(.headline)
                    Text(kindSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Picker("종류", selection: $filter) {
                    Text("전체").tag(CleanupKind?.none)
                    ForEach(CleanupKind.allCases, id: \.self) { kind in
                        if scan.count(of: kind) > 0 || kind != .appleDouble {
                            Text(kind.label).tag(CleanupKind?.some(kind))
                        }
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 320)
                Button("표시 항목 선택") { setSelection(true) }
                    .disabled(state.isBusy || visible.isEmpty)
                    .help("지금 목록에 보이는 항목만 선택합니다.")
                Button("표시 항목 해제") { setSelection(false) }
                    .disabled(state.isBusy || visible.isEmpty)
                    .help("지금 목록에 보이는 항목만 선택 해제합니다.")
            }

            if !scan.candidates.isEmpty {
                TextField("경로로 찾기 (예: 사진/2024)", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 420)
            }

            if !scan.isComplete {
                Label(incompleteText, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.httWarn)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if scan.candidates.isEmpty {
                HStack {
                    Spacer()
                    VStack(spacing: 8) {
                        Image(systemName: scan.isComplete ? "checkmark.seal.fill" : "questionmark.circle.fill")
                            .font(.system(size: 36))
                            .foregroundStyle(scan.isComplete ? HTTStyle(.success) : HTTStyle(.warn))
                        Text(scan.isComplete
                             ? "이 볼륨에는 정리할 파일이 없습니다."
                             : "확인한 범위에서는 정리할 파일이 없습니다. 확인하지 못한 폴더가 있어 볼륨 전체가 깨끗하다고 말할 수는 없습니다.")
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: 460)
                    }
                    .padding(.vertical, 24)
                    Spacer()
                }
            } else {
                Table(visible) {
                    TableColumn("") { candidate in
                        Toggle("", isOn: binding(for: candidate))
                            .labelsHidden()
                            .toggleStyle(.checkbox)
                            .disabled(state.isBusy)
                    }
                    .width(28)
                    TableColumn("경로") { candidate in
                        Text(candidate.relativePath)
                            .font(.body.monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(candidate.relativePath)
                            .contextMenu {
                                Button("Finder에서 보기") { state.revealInFinder(candidate, volume: volume) }
                            }
                    }
                    TableColumn("종류") { candidate in
                        Text(candidate.kind.label)
                            .foregroundStyle(.secondary)
                    }
                    .width(min: 90, ideal: 110, max: 140)
                    TableColumn("크기") { candidate in
                        Text(ByteFormat.string(candidate.size))
                            .monospacedDigit()
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .width(min: 70, ideal: 90, max: 110)
                }
                .frame(minHeight: 260, idealHeight: CGFloat(min(600, 28 * max(visible.count, 3) + 40)))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))

                if visible.isEmpty {
                    Text("검색어와 일치하는 항목이 없습니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("표시 \(visible.count)개 · 표시 중 선택 \(visible.filter { selectedIDs.contains($0.id) }.count)개 · 전체 선택 \(selectedIDs.count)개 · 확인 시각 \(Theme.dateFormatter.string(from: scan.finishedAt))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .card()
    }

    private var incompleteText: String {
        var text = "이 목록은 볼륨 전체를 다루지 못했습니다: " + scan.incompleteReasons.joined(separator: ". ") + "."
        if scan.truncated {
            text += " 지금 보이는 항목을 정리한 뒤 '다시 확인'을 실행하면 나머지를 이어서 볼 수 있습니다."
        } else {
            text += " 확인하지 못한 곳의 파일은 목록에 없습니다."
        }
        return text
    }

    /// 종류별 개수와 용량. 예: ".DS_Store 12개 · 72 KB".
    private var kindSummary: String {
        let parts = CleanupKind.allCases
            .filter { scan.count(of: $0) > 0 }
            .map { "\($0.label) \(scan.count(of: $0))개 · \(ByteFormat.string(scan.bytes(of: $0)))" }
        return parts.isEmpty ? "후보 없음" : parts.joined(separator: "  |  ")
    }

    private func setSelection(_ selected: Bool) {
        for candidate in visible {
            state.setSelected(selected, candidateID: candidate.id, volume: volume)
        }
    }

    private func binding(for candidate: USBCleanupCandidate) -> Binding<Bool> {
        Binding(
            get: { state.selectedIDs(for: volume).contains(candidate.id) },
            set: { state.setSelected($0, candidateID: candidate.id, volume: volume) }
        )
    }
}
