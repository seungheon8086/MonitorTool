import Darwin
import Foundation

/// 날짜별 네트워크 누적을 저장해요. 같은 날 앱을 다시 켜면 이어서 세요. (설계 문서 5장)
/// 매초 저장하지 않고 30초마다, 잠들기 전, 앱을 끌 때 묶어서 저장해요. (설계 문서 4장)
final class NetworkTotalsStore {
    private let defaults: UserDefaults
    private static let storageKey = "networkDailyTotals"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> [NetworkDayTotal] {
        guard let data = defaults.data(forKey: NetworkTotalsStore.storageKey),
              let saved = try? JSONDecoder().decode([NetworkDayTotal].self, from: data) else {
            return []
        }
        return saved
    }

    func save(_ days: [NetworkDayTotal]) {
        if let data = try? JSONEncoder().encode(days) {
            defaults.set(data, forKey: NetworkTotalsStore.storageKey)
        }
    }
}

/// 네트워크 속도와 누적을 재서 패널 값으로 만들어요.
/// 수집 일정(CollectionScheduler)이 패널이 열려 있으면 1초, 닫혀 있으면 5초마다 불러요.
final class NetworkCollector {
    /// 이번 실행을 시작한 시각 ('이번 실행' 누적의 시작)
    let sessionStartedAt = Date()

    private var meter: NetworkMeter
    private let totalsStore: NetworkTotalsStore
    /// BSD 이름 → 시스템 설정에 나오는 이름
    private var displayNames: [String: String] = [:]
    private var displayNamesReadAt = Date.distantPast
    private var savedAt = Date()

    /// 저장 간격 (초)
    private static let saveInterval: TimeInterval = 30
    /// 처음 보는 인터페이스가 있을 때 이름을 다시 읽는 최소 간격 (초)
    private static let displayNameRefreshInterval: TimeInterval = 60

    init(totalsStore: NetworkTotalsStore = NetworkTotalsStore()) {
        self.totalsStore = totalsStore
        meter = NetworkMeter(days: totalsStore.load())
    }

    /// 카운터를 한 번 읽어 패널 값을 만들어요.
    func collect(now: Date = Date()) -> NetworkSnapshot {
        guard let counters = InterfaceCounterReader.read() else {
            return makeSnapshot(rates: .unknown, counters: [:], now: now,
                                speedProblem: "인터페이스 카운터를 읽지 못했어요.")
        }
        let reading = NetworkReading(counters: counters,
                                     date: now,
                                     monotonic: clock_gettime_nsec_np(CLOCK_MONOTONIC),
                                     awake: clock_gettime_nsec_np(CLOCK_UPTIME_RAW))
        let rates = meter.add(reading, calendar: Calendar.current)
        refreshDisplayNamesIfNeeded(for: counters, now: now)
        if meter.hasUnsavedChanges, now.timeIntervalSince(savedAt) >= NetworkCollector.saveInterval {
            save()
        }
        return makeSnapshot(rates: rates, counters: counters, now: now, speedProblem: nil)
    }

    /// 지금까지의 날짜별 누적을 바로 저장해요. (잠들기 전, 앱을 끌 때)
    func save() {
        totalsStore.save(meter.days)
        meter.markSaved()
        savedAt = Date()
    }

    // MARK: - 패널 값 만들기

    private func makeSnapshot(rates: NetworkRates, counters: [String: InterfaceCounter], now: Date,
                              speedProblem: String?) -> NetworkSnapshot {
        let today = meter.total(on: NetworkMeter.dayKey(for: now, calendar: Calendar.current))
        var network = NetworkSnapshot()
        network.download = speedReading(rates.download, at: now, problem: speedProblem)
        network.upload = speedReading(rates.upload, at: now, problem: speedProblem)
        network.todayDownloaded = .ok(Double(today.received), at: now)
        network.todayUploaded = .ok(Double(today.sent), at: now)
        network.todayDate = now
        network.todayHasGap = today.hasGap
        network.sessionDownloaded = .ok(Double(meter.sessionReceived), at: now)
        network.sessionUploaded = .ok(Double(meter.sessionSent), at: now)
        network.sessionStartedAt = sessionStartedAt
        // 켜져 있고 한 번이라도 주고받은 장치만, 이름 순서로 보여줘요. (쓰지 않는 Thunderbolt 포트 등은 빼요)
        network.interfaces = counters.values
            .filter { NetworkMeter.isCounted($0.name) && $0.isActive && ($0.received > 0 || $0.sent > 0) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .compactMap { (counter: InterfaceCounter) -> InterfaceRate? in
                guard let speed = rates.interfaces[counter.name] else { return nil }
                return InterfaceRate(id: counter.name,
                                     displayName: displayNames[counter.name] ?? counter.name,
                                     download: speed.download,
                                     upload: speed.upload)
            }
        return network
    }

    /// 속도 값. 아직 두 표본이 없거나 믿을 수 없는 구간이면 '준비 중'이에요.
    private func speedReading(_ value: Double?, at date: Date, problem: String?) -> Reading<Double> {
        if let problem {
            return .failed(problem)
        }
        guard let value, value.isFinite, value >= 0 else {
            return .preparing
        }
        return .ok(value, at: date)
    }

    /// 처음 보는 장치가 있으면 시스템 설정의 이름을 다시 읽어요. (자주 읽지 않게 간격을 둬요)
    private func refreshDisplayNamesIfNeeded(for counters: [String: InterfaceCounter], now: Date) {
        let unknown = counters.values.contains { counter in
            NetworkMeter.isCounted(counter.name) && counter.isActive && displayNames[counter.name] == nil
        }
        guard unknown, now.timeIntervalSince(displayNamesReadAt) >= NetworkCollector.displayNameRefreshInterval else {
            return
        }
        displayNamesReadAt = now
        displayNames = InterfaceDisplayNames.read()
    }
}
