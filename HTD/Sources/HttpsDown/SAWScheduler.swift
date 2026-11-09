import Foundation
import Combine

/// SAW 프로젝트의 달력 정렬(hourly 분 00 / daily 지정 시각) 일정을 앱이 켜져 있는 동안만 점검한다.
/// OS 스케줄러나 Codex 자동화는 만들지 않으므로 앱이 꺼져 있던 동안의 정각은 깨어난 뒤
/// "가장 최근 1회"로만 따라잡고(백로그 재생 없음) 그 이전 정각은 건너뛴다.
@MainActor
final class SAWScheduler: ObservableObject {
    static let appOffLimitation = "앱이 실행 중일 때만 일정이 동작합니다. 앱이 꺼져 있거나 Mac이 잠자던 동안 놓친 정각은 다음 실행/깨어남 시점에 가장 최근 1회만 실행되고 나머지는 건너뜁니다."

    @Published private(set) var isRunning = false
    @Published private(set) var lastTickAt: Date?

    private let store: SAWProjectStore
    private let onDue: (UUID, String) -> Void
    private var timer: Timer?
    private var isTicking = false
    private var dispatchedSlots: [UUID: String] = [:]

    private static let pollInterval: TimeInterval = 15
    private static let activeStatusMarkers = ["queued", "running", "paused", "waiting", "usercontrol", "needsuser"]

    init(store: SAWProjectStore, onDue: @escaping (UUID, String) -> Void) {
        self.store = store
        self.onDue = onDue
    }

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        timer.tolerance = Self.pollInterval / 3
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        isRunning = true
        tick()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        isRunning = false
    }

    func tick(now: Date = Date()) {
        // 콜백이 같은 프로세스에서 tick을 다시 부르는 재진입을 막는다.
        guard !isTicking else { return }
        isTicking = true
        defer {
            isTicking = false
            lastTickAt = now
        }

        let projects = store.projects.sorted {
            $0.createdAt != $1.createdAt ? $0.createdAt < $1.createdAt : $0.id.uuidString < $1.id.uuidString
        }
        for project in projects {
            guard let key = Self.slot(for: project, now: now) else { continue }
            guard dispatchedSlots[project.id] != key else { continue }
            guard !store.hasProcessed(projectID: project.id, key: key) else { continue }

            if hasActiveRun(projectID: project.id) {
                // 겹치는 실행은 만들지 않고 이 정각은 소진해 늦게 몰아서 실행되지 않게 한다.
                recordSkipped(
                    projectID: project.id,
                    key: key,
                    startedAt: Self.parsedKey(key).map { Date(timeIntervalSince1970: TimeInterval($0.epoch)) } ?? now,
                    endedAt: now,
                    summary: "이전 작업이 진행 중이거나 멈춰 있어 이번 예약은 건너뛰었습니다."
                )
                store.markProcessed(projectID: project.id, key: key)
                dispatchedSlots[project.id] = key
                continue
            }
            // 내구성 있는 예약이 먼저 성공해야만 콜백을 부른다(쓰기 실패 시 false).
            guard store.reserveSlot(projectID: project.id, key: key) else { continue }
            dispatchedSlots[project.id] = key
            recordMissedGap(for: project, latestKey: key)
            onDue(project.id, key)
        }
    }

    private func recordSkipped(projectID: UUID, key: String, startedAt: Date, endedAt: Date, summary: String) {
        guard !store.runs.contains(where: { $0.projectID == projectID && $0.slotKey == key }) else { return }
        store.record(SAWRunRecord(
            projectID: projectID,
            slotKey: key,
            startedAt: startedAt,
            endedAt: endedAt,
            status: "skipped",
            summary: summary
        ))
    }

    /// 가장 최근 정각만 실행하므로, 그 이전에 실행 기록이 없는 정각 구간이 실제로 있을 때만 요약 기록 1건을 남긴다.
    private func recordMissedGap(for project: SAWProject, latestKey: String) {
        guard let latest = Self.parsedKey(latestKey) else { return }
        let missedKey = "missed|" + latestKey
        let latestBoundary = Date(timeIntervalSince1970: TimeInterval(latest.epoch))
        let knownEpoch = store.runs.compactMap { run -> Int? in
            guard run.projectID == project.id, let slotKey = run.slotKey,
                  let parsed = Self.parsedKey(slotKey),
                  parsed.frequency == latest.frequency, parsed.timeZoneID == latest.timeZoneID,
                  parsed.epoch < latest.epoch else { return nil }
            return parsed.epoch
        }.max()
        let known = knownEpoch.map { Date(timeIntervalSince1970: TimeInterval($0)) } ?? .distantPast
        let from = max(known, Self.activationAnchor(for: project))
        guard let firstDue = Self.nextRun(for: project, after: from), firstDue < latestBoundary else { return }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.timeZone = TimeZone(identifier: latest.timeZoneID)
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        let zone = latest.timeZoneID
        recordSkipped(
            projectID: project.id,
            key: missedKey,
            startedAt: firstDue,
            endedAt: latestBoundary,
            summary: "이전 예약 구간에는 실행 기록이 없어 건너뛰고 가장 최근 예약만 진행합니다 (\(formatter.string(from: firstDue)) 예약부터 \(formatter.string(from: latestBoundary)) 예약 전까지, \(zone))"
        )
    }

    /// `saw1|빈도|시간대|현지시각|오프셋|epoch` 형식만 해석한다.
    private static func parsedKey(_ key: String) -> (frequency: String, timeZoneID: String, epoch: Int)? {
        let parts = key.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count == 6, parts[0] == "saw1", let epoch = Int(parts[5]) else { return nil }
        return (String(parts[1]), String(parts[2]), epoch)
    }

    private func hasActiveRun(projectID: UUID) -> Bool {
        store.runs.contains { run in
            guard run.projectID == projectID else { return false }
            let status = run.status.lowercased().filter { $0.isLetter || $0.isNumber }
            return Self.activeStatusMarkers.contains { status.contains($0) }
        }
    }

    // MARK: - 결정적 계산

    /// `now` 이하의 가장 최근 정각 슬롯 키. 활성화 기준(생성 시각/notBefore) 이전/같은 정각, 비활성/수동/잘못된 설정은 nil.
    /// 키에는 빈도, 시간대 ID, 현지 시각, UTC 오프셋, 절대 epoch가 모두 들어가 DST로 반복되는 시각도 구별된다.
    static func slot(for project: SAWProject, now: Date) -> String? {
        guard let boundary = latestBoundary(for: project, now: now),
              let timeZone = TimeZone(identifier: project.schedule.timeZoneID) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: boundary)
        let local = String(format: "%04d-%02d-%02dT%02d:%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0)
        let offset = timeZone.secondsFromGMT(for: boundary)
        let epoch = Int(boundary.timeIntervalSince1970.rounded())
        return "saw1|\(frequency(of: project))|\(project.schedule.timeZoneID)|\(local)|\(offset)|\(epoch)"
    }

    /// `after`(및 활성화 기준) 이후의 첫 정각. 스케줄 비활성/수동/잘못된 설정이면 nil.
    static func nextRun(for project: SAWProject, after: Date) -> Date? {
        guard let context = context(for: project) else { return nil }
        let from = max(after, activationAnchor(for: project))
        let horizon: TimeInterval = context.frequency == "hourly" ? 7_200 : 172_800
        guard var best = boundary(atOrBefore: from.addingTimeInterval(horizon), context: context), best > from else { return nil }
        for _ in 0..<12 {
            guard let previous = boundary(atOrBefore: best.addingTimeInterval(-1), context: context), previous > from else { break }
            best = previous
        }
        return best
    }

    private struct Context {
        let frequency: String
        let hour: Int
        let minute: Int
        let timeZone: TimeZone
        let calendar: Calendar
    }

    private static func frequency(of project: SAWProject) -> String {
        project.schedule.frequency.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func context(for project: SAWProject) -> Context? {
        let schedule = project.schedule
        let frequency = frequency(of: project)
        guard schedule.enabled, !project.archived,
              frequency == "hourly" || frequency == "daily",
              let timeZone = TimeZone(identifier: schedule.timeZoneID) else { return nil }
        if frequency == "daily" {
            guard (0...23).contains(schedule.hour), (0...59).contains(schedule.minute) else { return nil }
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return Context(frequency: frequency, hour: schedule.hour, minute: schedule.minute, timeZone: timeZone, calendar: calendar)
    }

    private static func latestBoundary(for project: SAWProject, now: Date) -> Date? {
        guard let context = context(for: project),
              let boundary = boundary(atOrBefore: now, context: context),
              boundary > activationAnchor(for: project) else { return nil }
        return boundary
    }

    /// 일정 활성화 기준 시각. 생성 시각과 `schedule.notBefore` 중 늦은 쪽이며, 첫 정각은 이 값보다 엄격히 뒤여야 한다.
    private static func activationAnchor(for project: SAWProject) -> Date {
        max(project.createdAt, project.schedule.notBefore ?? project.createdAt)
    }

    private static func boundary(atOrBefore t: Date, context: Context) -> Date? {
        context.frequency == "hourly" ? hourlyBoundary(atOrBefore: t, timeZone: context.timeZone)
            : dailyBoundary(atOrBefore: t, context: context)
    }

    /// 현지 분 00인 가장 최근 시각. 오프셋을 직접 계산해 DST 반복 시각(두 번째 01:00)도 별개 정각으로 다룬다.
    private static func hourlyBoundary(atOrBefore t: Date, timeZone: TimeZone) -> Date? {
        var probe = t.timeIntervalSince1970.rounded(.down)
        for _ in 0..<8 {
            let offset = Double(timeZone.secondsFromGMT(for: Date(timeIntervalSince1970: probe)))
            let floored = ((probe + offset) / 3600).rounded(.down) * 3600
            let candidate = floored - offset
            let candidateOffset = Double(timeZone.secondsFromGMT(for: Date(timeIntervalSince1970: candidate)))
            if candidate + candidateOffset == floored { return Date(timeIntervalSince1970: candidate) }
            probe = candidate - 1
        }
        return nil
    }

    /// 현지 달력의 지정 시:분. 존재하지 않는 시각(봄 DST)은 Calendar가 보정한 시각을, 반복 시각은 첫 번째를 쓴다.
    private static func dailyBoundary(atOrBefore t: Date, context: Context) -> Date? {
        let calendar = context.calendar
        for back in 0..<3 {
            guard let day = calendar.date(byAdding: .day, value: -back, to: t) else { continue }
            var components = calendar.dateComponents([.year, .month, .day], from: day)
            components.hour = context.hour
            components.minute = context.minute
            components.second = 0
            if let candidate = calendar.date(from: components), candidate <= t { return candidate }
        }
        return nil
    }
}
