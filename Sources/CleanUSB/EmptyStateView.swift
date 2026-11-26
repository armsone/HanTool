import SwiftUI
import HTTThemeCore

struct CleanUSBEmptyStateView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: state.volumes.isEmpty ? "externaldrive.badge.xmark" : "externaldrive.badge.questionmark")
                .font(.system(size: 64, weight: .light))
                .foregroundStyle(Theme.gradient)
            Text(state.volumes.isEmpty ? "연결된 외장 디스크가 없습니다" : "왼쪽 목록에서 볼륨을 선택하세요")
                .font(.title2.weight(.semibold))
            Text(state.volumes.isEmpty
                 ? "USB 메모리나 외장 디스크를 연결하면 자동으로 목록에 나타납니다.\n외장·로컬·쓰기 가능한 물리 디스크만 표시하며, 내장 디스크·네트워크 드라이브·디스크 이미지·읽기 전용 볼륨과 물리 디스크를 확인할 수 없는 볼륨은 표시하지 않습니다."
                 : "볼륨을 선택한 뒤 '정리할 파일 확인'을 눌러야 검사가 시작됩니다. 자동으로 검사하지 않습니다.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 460)
            if state.volumes.isEmpty && !state.excludedVolumes.isEmpty {
                Text("표시하지 않은 볼륨: " + state.excludedVolumes.map { "\($0.name)(\($0.reason))" }.joined(separator: ", "))
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 460)
            }
            if state.volumes.isEmpty {
                Button {
                    state.refreshVolumes()
                } label: {
                    Label("다시 확인", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
                .disabled(state.isRefreshing)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.httPaper)
    }
}
