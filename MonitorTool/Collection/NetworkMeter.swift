import Foundation

/// 날짜 하나의 네트워크 누적이에요. 원본 바이트로 저장해요. (설계 문서 3·5장)
nonisolated struct NetworkDayTotal: Codable, Hashable, Sendable {
    /// 로컬 달력 날짜 (예: "2026-10-24")
    var day: String
    /// 받은 바이트
    var received: UInt64 = 0
    /// 보낸 바이트
    var sent: UInt64 = 0
    /// 어느 날 양인지 나눌 수 없어 빠진 양이 있는지 (예: 자정을 넘겨 잠든 동안)
    var hasGap = false
}

/// 카운터를 한 번 읽은 결과와 그때의 시각들이에요.
nonisolated struct NetworkReading: Sendable {
    var counters: [String: InterfaceCounter]
    /// 날짜를 나눌 때 쓰는 벽시계 시각
    var date: Date
    /// 속도 계산용 시계 (나노초). 잠든 시간도 세고, 시계를 바꿔도 영향받지 않아요.
    var monotonic: UInt64
    /// 깨어 있던 시간만 세는 시계 (나노초). monotonic보다 덜 늘었으면 그사이에 잠들었던 거예요.
    var awake: UInt64
}

/// 인터페이스 하나의 속도 (바이트/초)
nonisolated struct InterfaceSpeed: Hashable, Sendable {
    var download: Double
    var upload: Double
}

/// 한 번 잰 속도예요. 기준이 되는 표본이 없거나 믿을 수 없는 구간이면 nil(미확정)이에요.
nonisolated struct NetworkRates: Sendable {
    var download: Double?
    var upload: Double?
    /// 인터페이스별 속도 (앞뒤 두 표본이 다 있는 것만)
    var interfaces: [String: InterfaceSpeed]

    static let unknown = NetworkRates(download: nil, upload: nil, interfaces: [:])
}

/// 네트워크 누적을 세는 규칙이에요. 화면·저장과 떨어뜨려 두어서 규칙만 따로 시험할 수 있어요. (설계 문서 5장)
/// - 이름이 en으로 시작하는 실제 장치(Wi-Fi·이더넷·Thunderbolt·iPhone USB)만 세요.
///   VPN(utun·ipsec), AirDrop(awdl·llw), 브리지(bridge), loopback(lo)은 같은 트래픽을 겹쳐 세게 되거나 실제 전송이 아니라서 빼요.
/// - 카운터가 줄었거나 새로 생긴 인터페이스는 새 기준점만 잡아요. (재생성·재부팅)
/// - 같은 날 안의 구간은 그날에 더해요. 자정을 걸친 짧은 구간(날짜 경계 표본 사이)은 새 날짜에 더해요.
///   자정을 넘겨 잠든 구간처럼 날짜를 나눌 수 없으면 어느 날에도 더하지 않고 두 날짜에 '빠진 양 있음'을 표시해요.
/// - 이번 실행 누적은 날짜와 상관없이 다 더해요. 앱이 꺼져 있던 동안은 기준점이 없어서 세지 않아요.
/// - 속도는 실제 지난 시간으로 계산하고, 잠든 구간·인터페이스가 바뀐 구간은 미확정으로 둬요.
nonisolated struct NetworkMeter {
    /// 남겨 두는 날짜 수
    static let keptDays = 7
    /// 자정을 걸친 구간이 이보다 짧으면 새 날짜에 더해요. (경계 표본이 있어서 보통 1초 안팎이에요)
    static let shortBoundaryInterval: TimeInterval = 60
    /// 두 시계가 이보다 많이 벌어지면 그사이에 잠든 걸로 봐요. (초)
    static let sleepThreshold: TimeInterval = 2
    /// 앞 표본과 이보다 가까우면 속도를 새로 계산하지 않고 앞의 값을 그대로 써요. (초)
    static let minimumSpeedInterval: TimeInterval = 0.5

    /// 이번 실행 동안 받은·보낸 바이트 (앱을 켤 때 0부터)
    private(set) var sessionReceived: UInt64 = 0
    private(set) var sessionSent: UInt64 = 0
    /// 날짜별 누적 (오래된 날짜부터, 최근 keptDays일)
    private(set) var days: [NetworkDayTotal]
    /// 저장한 뒤로 바뀐 것이 있는지
    private(set) var hasUnsavedChanges = false

    /// 바로 앞 표본 (다음 표본과의 차이를 세는 기준점)
    private var previous: NetworkReading?
    /// 바로 앞에 계산한 속도
    private var lastRates = NetworkRates.unknown

    init(days: [NetworkDayTotal]) {
        self.days = days.sorted { $0.day < $1.day }
    }

    /// 누적에 넣는 인터페이스인지
    static func isCounted(_ name: String) -> Bool {
        name.hasPrefix("en")
    }

    /// 로컬 달력 날짜 이름 (예: "2026-10-24")
    static func dayKey(for date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// 그 날짜의 누적 (아직 없으면 0)
    func total(on day: String) -> NetworkDayTotal {
        days.first { $0.day == day } ?? NetworkDayTotal(day: day)
    }

    mutating func markSaved() {
        hasUnsavedChanges = false
    }

    /// 새로 읽은 카운터를 누적에 더하고, 이번 구간의 속도를 돌려줘요.
    mutating func add(_ reading: NetworkReading, calendar: Calendar) -> NetworkRates {
        let today = Self.dayKey(for: reading.date, calendar: calendar)
        ensureDay(today)

        guard let previous else {
            // 첫 표본은 기준점이에요. 속도는 다음 표본부터 알 수 있어요.
            self.previous = reading
            lastRates = .unknown
            return lastRates
        }
        self.previous = reading

        let elapsed = Self.seconds(from: previous.monotonic, to: reading.monotonic)
        let awakeElapsed = Self.seconds(from: previous.awake, to: reading.awake)
        let slept = elapsed - awakeElapsed > Self.sleepThreshold
        let canMeasureSpeed = !slept && elapsed >= Self.minimumSpeedInterval
        var totalSpeedKnown = canMeasureSpeed

        var received: UInt64 = 0
        var sent: UInt64 = 0
        var speeds: [String: InterfaceSpeed] = [:]
        for (name, counter) in reading.counters where Self.isCounted(name) {
            guard let old = previous.counters[name] else {
                // 새로 생긴 인터페이스: 이번에는 기준점만 잡아요.
                totalSpeedKnown = false
                continue
            }
            guard counter.received >= old.received, counter.sent >= old.sent else {
                // 카운터가 줄었어요. 인터페이스가 다시 생긴 거라 새 기준점만 잡아요.
                totalSpeedKnown = false
                continue
            }
            let receivedDelta = counter.received - old.received
            let sentDelta = counter.sent - old.sent
            received &+= receivedDelta
            sent &+= sentDelta
            if canMeasureSpeed {
                speeds[name] = InterfaceSpeed(download: Double(receivedDelta) / elapsed,
                                              upload: Double(sentDelta) / elapsed)
            }
        }
        // 사라진 인터페이스가 있으면 이번 구간의 합계 속도는 믿을 수 없어요.
        let disappeared = previous.counters.keys.contains { name in
            Self.isCounted(name) && reading.counters[name] == nil
        }
        if disappeared {
            totalSpeedKnown = false
        }

        sessionReceived &+= received
        sessionSent &+= sent
        if received > 0 || sent > 0 {
            let dayBefore = Self.dayKey(for: previous.date, calendar: calendar)
            if dayBefore == today || (!slept && elapsed <= Self.shortBoundaryInterval) {
                addToDay(today, received: received, sent: sent)
            } else {
                markGap(on: dayBefore)
                markGap(on: today)
            }
        }

        if !slept && elapsed < Self.minimumSpeedInterval {
            // 바로 앞에 잰 지 얼마 안 됐어요(날짜 경계 표본 등). 앞에 계산한 속도를 그대로 써요.
            return lastRates
        }
        lastRates = NetworkRates(download: totalSpeedKnown ? Double(received) / elapsed : nil,
                                 upload: totalSpeedKnown ? Double(sent) / elapsed : nil,
                                 interfaces: speeds)
        return lastRates
    }

    // MARK: - 날짜별 누적

    private mutating func ensureDay(_ day: String) {
        guard !days.contains(where: { $0.day == day }) else { return }
        days.append(NetworkDayTotal(day: day))
        days.sort { $0.day < $1.day }
        // 오래된 날짜부터 지워요. 방금 넣은 날짜는 남겨요. (시계를 과거로 돌렸을 때도 오늘이 지워지지 않게)
        while days.count > Self.keptDays, let oldest = days.firstIndex(where: { $0.day != day }) {
            days.remove(at: oldest)
        }
        hasUnsavedChanges = true
    }

    private mutating func addToDay(_ day: String, received: UInt64, sent: UInt64) {
        ensureDay(day)
        guard let index = days.firstIndex(where: { $0.day == day }) else { return }
        days[index].received &+= received
        days[index].sent &+= sent
        hasUnsavedChanges = true
    }

    private mutating func markGap(on day: String) {
        ensureDay(day)
        guard let index = days.firstIndex(where: { $0.day == day }) else { return }
        days[index].hasGap = true
        hasUnsavedChanges = true
    }

    /// 두 시계 값 사이의 초 (거꾸로 가면 0)
    private static func seconds(from start: UInt64, to end: UInt64) -> TimeInterval {
        end > start ? Double(end - start) / 1_000_000_000 : 0
    }
}
