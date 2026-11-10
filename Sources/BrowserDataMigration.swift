import AppKit
import Foundation
import OSLog

/// 이전 HTD(com.hanstree.HttpsDown)의 웹킷 데이터 저장소를 새 호스트(com.local.screentranslator)로
/// 안전하게 일회성 오프라인 복사(복사 전용, 원본 보존, 대상 덮어쓰기 금지)한다.
@MainActor
public enum BrowserDataMigration {
    private static let logger = Logger(subsystem: "com.local.screentranslator", category: "BrowserDataMigration")
    public static let legacyBundleIdentifier = "com.hanstree.HttpsDown"
    public static let hostBundleIdentifier = "com.local.screentranslator"

    private static let namedStoreUUIDs = [
        "6f1d2b7a-3c54-4e8b-9a10-48d7c5e21b93",
        "b3a8e0c4-5d17-4f62-8e39-0c6a71d94f25"
    ]

    private static var markerURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("Library/WebKit/\(hostBundleIdentifier)/.browser_migration_done")
    }

    /// 기존 레거시 HttpsDown 앱이 실행 중인지 확인한다.
    public static func isLegacyAppRunning() -> Bool {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: legacyBundleIdentifier)
        return apps.contains { !$0.isTerminated }
    }

    /// 레거시 HttpsDown 앱이 실행 중일 때 사용자에게 안내 대화상자를 띄운다(종료/강제 종료하지 않음).
    public static func showLegacyRunningAlert() {
        let alert = NSAlert()
        alert.messageText = "이전 브라우저(HttpsDown)가 실행 중입니다"
        alert.informativeText = "기존 HttpsDown 브라우저가 실행 중인 상태에서는 브라우저 작업 공간을 시작할 수 없습니다. 진행 중인 다운로드나 작업을 완료한 뒤 HttpsDown을 먼저 종료해 주세요. 실행 중인 앱을 자동으로 종료하지 않습니다."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "확인")
        alert.runModal()
    }

    public enum MigrationResult {
        case alreadyDone
        case freshInstall
        case migrated(count: Int)
        case blockedLegacyRunning
        case failed(String)

        public var isSuccess: Bool {
            switch self {
            case .alreadyDone, .freshInstall, .migrated:
                return true
            case .blockedLegacyRunning, .failed:
                return false
            }
        }
    }

    private enum MigrationError: LocalizedError {
        case legacyAppRestarted
        case targetAlreadyExists(String)

        var errorDescription: String? {
            switch self {
            case .legacyAppRestarted:
                return "데이터 마이그레이션 중 이전 브라우저(HttpsDown)가 실행되어 중단되었습니다. HttpsDown을 종료한 후 다시 시도해 주세요."
            case .targetAlreadyExists(let name):
                return "대상 저장소(\(name))가 스테이징 중 이미 생성되었습니다."
            }
        }
    }

    /// HTDHostExport.shared / AppModel 생성 전에 실행하는 오프라인 복사 마이그레이션.
    /// - 레거시 앱이 실행 중이면 즉시 중단하고 안내한다.
    /// - 대상이 이미 있으면 덮어쓰지 않고 유지한다.
    /// - 소스가 없으면 신규 설치로 처리한다.
    /// - 복사 실패 시 스테이징 및 이번 호출에서 생성한 대상 클론만 정리하고 실패를 반환한다(원본 및 기존 데이터 보존).
    public static func performMigrationIfNeeded() -> MigrationResult {
        // 1. 레거시 실행 여부 즉시 검사
        if isLegacyAppRunning() {
            logger.warning("Legacy application \(legacyBundleIdentifier) is running. Migration blocked.")
            showLegacyRunningAlert()
            return .blockedLegacyRunning
        }

        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser

        let legacyWebKitDir = home.appendingPathComponent("Library/WebKit/\(legacyBundleIdentifier)", isDirectory: true)
        let hostWebKitDir = home.appendingPathComponent("Library/WebKit/\(hostBundleIdentifier)", isDirectory: true)

        let marker = markerURL
        if fileManager.fileExists(atPath: marker.path) {
            if isLegacyAppRunning() {
                showLegacyRunningAlert()
                return .blockedLegacyRunning
            }
            return .alreadyDone
        }

        // 2. 복사 직전 레거시 실행 여부 재확인
        if isLegacyAppRunning() {
            showLegacyRunningAlert()
            return .blockedLegacyRunning
        }

        var copiedItems = 0
        var stagingDirectories: [URL] = []
        var ownedCreatedTargets: [URL] = []
        var legacySourceFound = false
        var skippedExistingCount = 0

        defer {
            // 이번 호출에서 남은 스테이징 디렉터리 정리
            for staging in stagingDirectories {
                if fileManager.fileExists(atPath: staging.path) {
                    try? fileManager.removeItem(at: staging)
                }
            }
        }

        do {
            try fileManager.createDirectory(at: hostWebKitDir, withIntermediateDirectories: true)
            let hostDataStoreDir = hostWebKitDir.appendingPathComponent("WebsiteDataStore", isDirectory: true)
            try fileManager.createDirectory(at: hostDataStoreDir, withIntermediateDirectories: true)

            let legacyDataStoreDir = legacyWebKitDir.appendingPathComponent("WebsiteDataStore", isDirectory: true)

            // 고정 지정된 명명 데이터스토어 복사
            for uuid in namedStoreUUIDs {
                let sourceStore = legacyDataStoreDir.appendingPathComponent(uuid, isDirectory: true)
                let targetStore = hostDataStoreDir.appendingPathComponent(uuid, isDirectory: true)

                let sourceExists = fileManager.fileExists(atPath: sourceStore.path)
                if sourceExists {
                    legacySourceFound = true
                }

                // 대상이 이미 있으면 유지
                if fileManager.fileExists(atPath: targetStore.path) {
                    if sourceExists {
                        skippedExistingCount += 1
                    }
                    continue
                }

                // 원본이 없으면 건너뜀
                guard sourceExists else {
                    continue
                }

                // 소스 복사 직전 레거시 실행 여부 재확인
                if isLegacyAppRunning() {
                    throw MigrationError.legacyAppRestarted
                }

                let stagingDir = hostDataStoreDir.appendingPathComponent(".\(uuid).staging-\(UUID().uuidString)")
                stagingDirectories.append(stagingDir)

                try fileManager.copyItem(at: sourceStore, to: stagingDir)

                // 소스 복사 후 커밋(이동) 직전 레거시 실행 여부 재확인
                if isLegacyAppRunning() {
                    throw MigrationError.legacyAppRestarted
                }

                if fileManager.fileExists(atPath: targetStore.path) {
                    throw MigrationError.targetAlreadyExists(uuid)
                }

                try fileManager.moveItem(at: stagingDir, to: targetStore)
                ownedCreatedTargets.append(targetStore)
                copiedItems += 1
            }

            // WebExtensions 디렉터리 보존 (대상 없을 때만)
            let legacyWebExt = legacyWebKitDir.appendingPathComponent("WebExtensions", isDirectory: true)
            let targetWebExt = hostWebKitDir.appendingPathComponent("WebExtensions", isDirectory: true)
            let webExtSourceExists = fileManager.fileExists(atPath: legacyWebExt.path)
            if webExtSourceExists {
                legacySourceFound = true
            }

            let webExtTargetExists = fileManager.fileExists(atPath: targetWebExt.path)
            if webExtTargetExists {
                if webExtSourceExists {
                    skippedExistingCount += 1
                }
            } else if webExtSourceExists {
                // 소스 복사 직전 레거시 실행 여부 재확인
                if isLegacyAppRunning() {
                    throw MigrationError.legacyAppRestarted
                }

                let stagingWebExt = hostWebKitDir.appendingPathComponent(".WebExtensions.staging-\(UUID().uuidString)")
                stagingDirectories.append(stagingWebExt)

                try fileManager.copyItem(at: legacyWebExt, to: stagingWebExt)

                // 소스 복사 후 커밋(이동) 직전 레거시 실행 여부 재확인
                if isLegacyAppRunning() {
                    throw MigrationError.legacyAppRestarted
                }

                if fileManager.fileExists(atPath: targetWebExt.path) {
                    throw MigrationError.targetAlreadyExists("WebExtensions")
                }

                try fileManager.moveItem(at: stagingWebExt, to: targetWebExt)
                ownedCreatedTargets.append(targetWebExt)
                copiedItems += 1
            }

            // 마커 기록 직전 레거시 실행 여부 최종 재확인
            if isLegacyAppRunning() {
                throw MigrationError.legacyAppRestarted
            }

            // 모든 복사가 정상 완료된 후에만 마커 파일 기록 (멱등성 보장)
            let markerData = "migrated=\(Date())\ncopied=\(copiedItems)\n".data(using: .utf8) ?? Data()
            try markerData.write(to: marker, options: .atomic)

            logger.info("Browser data migration completed. Copied items: \(copiedItems)")
            if copiedItems > 0 {
                return .migrated(count: copiedItems)
            } else if skippedExistingCount > 0 || legacySourceFound {
                return .alreadyDone
            } else if fileManager.fileExists(atPath: legacyWebKitDir.path) {
                return .alreadyDone
            } else {
                return .freshInstall
            }
        } catch {
            logger.error("Browser data migration error: \(error.localizedDescription)")

            var rollbackFailures: [String] = []

            // 이번 호출에서 새로 생성된 대상 클론만 롤백 (원본, 기존 대상, 부모 네임스페이스 보존)
            for target in ownedCreatedTargets {
                if fileManager.fileExists(atPath: target.path) {
                    do {
                        try fileManager.removeItem(at: target)
                    } catch {
                        rollbackFailures.append("대상 클론(\(target.lastPathComponent)): \(error.localizedDescription)")
                    }
                }
            }

            // 이번 호출의 스테이징 디렉터리 정리
            for staging in stagingDirectories {
                if fileManager.fileExists(atPath: staging.path) {
                    do {
                        try fileManager.removeItem(at: staging)
                    } catch {
                        rollbackFailures.append("스테이징(\(staging.lastPathComponent)): \(error.localizedDescription)")
                    }
                }
            }

            let failureDetail: String
            if rollbackFailures.isEmpty {
                failureDetail = error.localizedDescription
            } else {
                failureDetail = "\(error.localizedDescription) (롤백 실패: \(rollbackFailures.joined(separator: ", ")))"
            }

            return .failed(failureDetail)
        }
    }
}
