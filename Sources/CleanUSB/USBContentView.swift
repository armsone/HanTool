import SwiftUI

struct CleanUSBPane: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("USB 드라이브")
                    .font(.headline)
                Spacer()
                Button {
                    state.refreshVolumes()
                } label: {
                    if state.isRefreshing {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("새로 고침", systemImage: "arrow.clockwise")
                    }
                }
                .help("연결된 외장 볼륨 목록을 다시 읽습니다")
                .disabled(state.isRefreshing)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .alert(item: $state.pendingAction) { action in
                confirmationAlert(action)
            }

            Divider()

            HSplitView {
                SidebarView()
                    .frame(minWidth: 160, idealWidth: 240, maxWidth: 320, maxHeight: .infinity)
                detailContent
                    .frame(minWidth: 330, maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        Group {
            if let volume = state.selectedVolume {
                VolumeDetailView(volume: volume)
                    .id(volume.id)
            } else {
                CleanUSBEmptyStateView()
            }
        }
        .alert(item: $state.alert) { info in
            Alert(title: Text(info.title), message: Text(info.message), dismissButton: .default(Text("확인")))
        }
    }

    private func confirmationAlert(_ action: PendingAction) -> Alert {
        switch action.kind {
        case .cleanup(let thenEject):
            let title = "'\(action.volume.name)'에서 \(action.count)개 파일을 삭제할까요?"
            var lines = ["합계 \(ByteFormat.string(action.bytes)). 삭제한 파일은 이 앱에서 되돌릴 수 없습니다."]
            if action.appleDoubleCount > 0 {
                lines.append("._ 부속 파일 \(action.appleDoubleCount)개가 포함되어 있습니다. 리소스 포크·태그가 사라질 수 있습니다.")
            }
            lines.append("이 창을 연 시점에 선택한 항목만 지웁니다. 그 뒤 목록이 바뀌면 실행하지 않습니다.")
            if thenEject {
                lines.append("모든 파일이 정상적으로 삭제된 경우에만 이어서 추출합니다.")
            }
            return Alert(
                title: Text(title),
                message: Text(lines.joined(separator: "\n")),
                primaryButton: .destructive(Text(thenEject ? "삭제 후 추출" : "\(action.count)개 삭제")) {
                    state.performPendingAction(action)
                },
                secondaryButton: .cancel(Text("취소"))
            )
        }
    }
}
