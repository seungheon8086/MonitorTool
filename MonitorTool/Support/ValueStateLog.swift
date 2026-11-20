import Foundation

/// 항목 값의 상태가 바뀌면 기록에 남겨요. 실사용 점검에서 잠자기·오래 켜 두기 뒤 어떤 값이 언제 멈췄는지 보려고 둬요. (2026-11-21)
/// - 문제 상태(실패·오래됨·허용 필요)로 들어가거나 나올 때만 남겨요.
///   준비 중 → 정상, 정상 ↔ 꺼짐(ANE·GPU 온도), 측정 불가(응답 시간 등)는 평소 일이라 남기지 않아요.
/// - 오래됨은 몇 초 전 값인지가 계속 바뀌어서 오래됨끼리는 같은 상태로 봐요.
/// - 준비 중이 60초를 넘으면 한 번 남기고, 그 뒤 값이 오면 걸린 시간을 남겨요.
/// - 화면이 꺼진 동안은 CPU·ANE 전력을 일부러 묻지 않아요. 그때 오래됨이 되는 건 남기지 않고, 다시 정상이 될 때도 남기지 않아요.
/// - 디스크가 연결되거나 빠지면 남겨요. 값(숫자)은 남기지 않아요.
nonisolated struct ValueStateLog {
    /// 준비 중이 이보다 길면 남겨요. (초)
    private static let preparingLimit: TimeInterval = 60

    private var states: [String: ValueState] = [:]
    private var preparingSince: [String: Date] = [:]
    private var reportedPreparing: Set<String> = []
    /// 화면이 꺼진 동안 오래됨이 되어 남기지 않은 항목
    private var quietStale: Set<String> = []
    /// 마지막으로 본 디스크 (nil이면 아직 목록을 못 봤어요)
    private var disks: [UInt64: String]?

    mutating func check(_ snapshot: MonitorSnapshot, screensAsleep: Bool, now: Date = Date()) {
        checkDisks(snapshot.disk)
        var present = Set<String>()
        for (name, state) in ValueStateLog.items(in: snapshot) {
            present.insert(name)
            let old = states[name] ?? .preparing
            states[name] = state
            trackPreparing(name, new: state, now: now)
            guard !ValueStateLog.same(old, state), old.isProblem || state.isProblem else { continue }
            if case .stale = state, screensAsleep, !old.isProblem {
                quietStale.insert(name)
                continue
            }
            // 화면이 꺼진 동안 오래됨이 됐다가 다시 정상이 됐어요.
            if quietStale.remove(name) != nil, !state.isProblem {
                continue
            }
            let line = "\(name): \(old.logText) → \(state.logText)"
            if case .failed = state {
                AppLog.error(.values, line)
            } else {
                AppLog.notice(.values, line)
            }
        }
        // 빠진 항목(빠진 디스크 등)은 잊어요.
        states = states.filter { present.contains($0.key) }
        preparingSince = preparingSince.filter { present.contains($0.key) }
        reportedPreparing.formIntersection(present)
        quietStale.formIntersection(present)
    }

    private mutating func trackPreparing(_ name: String, new: ValueState, now: Date) {
        if new == .preparing {
            let since = preparingSince[name] ?? now
            preparingSince[name] = since
            let waited = now.timeIntervalSince(since)
            if waited >= ValueStateLog.preparingLimit, reportedPreparing.insert(name).inserted {
                AppLog.notice(.values, "\(name): 준비 중 \(AppLog.duration(waited)) 넘음")
            }
        } else if let since = preparingSince.removeValue(forKey: name),
                  reportedPreparing.remove(name) != nil, !new.isProblem {
            // 문제 상태로 바뀐 경우는 위에서 '준비 중 → …'으로 남겨요.
            AppLog.notice(.values, "\(name): 준비 중 → \(new.logText) (\(AppLog.duration(now.timeIntervalSince(since))) 만에)")
        }
    }

    private mutating func checkDisks(_ disk: DiskSnapshot) {
        guard let list = disk.disks.okValue else { return }
        let labels = list.map { ($0.id, ValueStateLog.label(of: $0)) }
        let current = Dictionary(labels, uniquingKeysWith: { first, _ in first })
        if let disks {
            for (id, label) in labels where disks[id] == nil {
                AppLog.notice(.values, "디스크 연결: \(label)")
            }
            for (id, label) in disks.sorted(by: { $0.value < $1.value }) where current[id] == nil {
                AppLog.notice(.values, "디스크 빠짐: \(label)")
            }
        } else {
            AppLog.notice(.values, "디스크: " + labels.map { $0.1 }.joined(separator: ", "))
        }
        disks = current
    }

    private static func label(of disk: DiskReading) -> String {
        "\(disk.name) (\(disk.bsdName))"
    }

    /// 오래됨끼리는 몇 초 전 값인지와 상관없이 같은 상태예요.
    private static func same(_ first: ValueState, _ second: ValueState) -> Bool {
        if case .stale = first, case .stale = second {
            return true
        }
        return first == second
    }

    /// 상태를 지켜볼 항목 (이름, 상태)
    private static func items(in snapshot: MonitorSnapshot) -> [(String, ValueState)] {
        let cpu = snapshot.cpu
        let gpu = snapshot.gpu
        let ane = snapshot.ane
        let memory = snapshot.memory
        let thermal = snapshot.thermal
        let battery = snapshot.battery
        var items: [(String, ValueState)] = [
            ("CPU E 사용률", cpu.efficiencyUsage.state),
            ("CPU P 사용률", cpu.performanceUsage.state),
            ("CPU 전력", cpu.power.state),
            ("GPU 사용률", gpu.usage.state),
            ("GPU 전력", gpu.power.state),
            ("GPU 메모리", gpu.memory.state),
            ("ANE 사용 중", ane.isActive.state),
            ("ANE 전력", ane.power.state),
            ("ANE 메모리 트래픽", ane.dramTraffic.state),
            ("ANE 온도", ane.temperature.state),
            ("메모리 사용량", memory.used.state),
            ("메모리 압력", memory.pressure.state),
            ("스왑", memory.swapUsed.state),
            ("메모리 트래픽", memory.trafficTotal.state),
            ("CPU 온도", thermal.cpuMax.state),
            ("GPU 온도", thermal.gpuMax.state),
            ("배터리 온도", thermal.battery.state),
            ("SSD 온도", thermal.ssd.state),
            ("팬", thermal.fans.state),
            ("배터리 잔량", battery.level.state),
            ("충전 상태", battery.chargeState.state),
            ("배터리 순전력", battery.netPower.state),
            ("남은 시간", battery.timeRemaining.state),
            ("배터리 성능 상태", battery.condition.state),
            ("최대 용량", battery.maximumCapacity.state),
            ("충전 횟수", battery.cycleCount.state),
            ("네트워크 속도", snapshot.network.download.state),
            ("오늘 네트워크", snapshot.network.todayDownloaded.state),
            ("디스크", snapshot.disk.disks.state),
        ]
        let fans = thermal.fans.okValue ?? []
        for fan in fans {
            items.append(("\(FanName.long(id: fan.id, count: fans.count)) 회전수", fan.rpm.state))
        }
        for disk in snapshot.disk.disks.okValue ?? [] {
            let label = ValueStateLog.label(of: disk)
            items.append(("\(label) 읽기·쓰기", disk.read.state))
            items.append(("\(label) 활성", disk.active.state))
            items.append(("\(label) 오늘 누적", disk.todayRead.state))
            if let smart = disk.smart {
                items.append(("\(label) SMART", smart.state))
            }
        }
        return items
    }
}

extension ValueState {
    /// 기록에 남길 만한 문제 상태인지
    nonisolated fileprivate var isProblem: Bool {
        switch self {
        case .failed, .stale, .permissionNeeded: true
        case .ok, .preparing, .unsupported, .notMeasurable, .off: false
        }
    }

    /// 기록용 글
    nonisolated var logText: String {
        switch self {
        case .ok: "정상"
        case .preparing: "준비 중"
        case .unsupported: "미지원"
        case .permissionNeeded: "허용 필요"
        case .notMeasurable(let reason): "측정 불가 (\(reason))"
        case .off: "꺼짐"
        case .failed(let message): "실패 (\(message))"
        case .stale(let age): "오래됨 (\(age)초 전 값)"
        }
    }
}

extension HelperStatus {
    /// 기록용 글
    nonisolated var logText: String {
        switch self {
        case .unknown: "확인 전"
        case .notRegistered: "꺼짐"
        case .requiresApproval: "허용 필요"
        case .enabled: "동작 중"
        case .failed: "연결 실패"
        }
    }
}
