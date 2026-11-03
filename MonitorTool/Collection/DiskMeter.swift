import Foundation

/// 날짜 하나, 디스크 하나의 누적이에요. 원본 바이트로 저장해요. (docs/DISK_IO.md)
nonisolated struct DiskDayTotal: Codable, Hashable, Sendable {
    /// 로컬 달력 날짜 (예: "2026-11-03")
    var day: String
    /// 디스크 고정 키 (DiskDevice.key)
    var key: String
    var read: UInt64 = 0
    var written: UInt64 = 0
    /// 어느 날 양인지 나눌 수 없어 빠진 양이 있는지 (예: 자정을 넘겨 잠든 동안)
    var hasGap = false
}

/// 카운터를 한 번 읽은 결과와 그때의 시각들이에요.
nonisolated struct DiskSample: Sendable {
    /// IORegistry 항목 ID → 카운터
    var counters: [UInt64: DiskCounter]
    /// IORegistry 항목 ID → 고정 키
    var keys: [UInt64: String]
    /// 날짜를 나눌 때 쓰는 벽시계 시각
    var date: Date
    /// 속도 계산용 시계 (나노초, 잠든 시간도 셈)
    var monotonic: UInt64
    /// 깨어 있던 시간만 세는 시계 (나노초)
    var awake: UInt64
}

/// 디스크 하나의 이번 구간 값이에요.
nonisolated struct DiskRates: Hashable, Sendable {
    /// 바이트/초
    var read: Double
    var write: Double
    /// 초당 작업 수
    var readOperations: Double
    var writeOperations: Double
    /// 평균 동시 요청 수
    var queueDepth: Double
    /// 작업 하나의 평균 응답 시간 (초). 그 방향 작업이 적으면 nil이에요.
    var readLatency: Double?
    var writeLatency: Double?
}

/// 디스크 I/O를 세는 규칙이에요. 화면·저장과 떨어뜨려 두어서 규칙만 따로 시험할 수 있어요.
/// 네트워크 누적(NetworkMeter)과 같은 규칙이에요.
/// - 카운터가 줄었거나 새로 생긴 디스크는 새 기준점만 잡아요. (다시 꽂음·재부팅)
/// - 같은 날 안의 구간은 그날에 더해요. 자정을 걸친 짧은 구간은 새 날짜에, 자정을 넘겨 잠든 구간은 '빠진 양 있음'으로.
/// - 속도는 실제 지난 시간으로 계산하고, 잠든 구간은 미확정으로 둬요.
/// - 평균 동시 요청 = 걸린 시간 합의 증가량 ÷ 구간 (활성 시간 %가 아니라서 1을 넘을 수 있어요, Diagnostics/DiskProbe)
/// - 응답 시간 = 걸린 시간 증가량 ÷ 작업 수 증가량. 작업이 초당 minimumOperationsForLatency개보다 적으면 보이지 않아요.
///   (진단: 작업이 1~3개뿐인 구간은 쉬던 디스크가 깨어나는 시간 때문에 0.8~1.3 ms로 튐)
nonisolated struct DiskMeter {
    static let keptDays = 7
    static let shortBoundaryInterval: TimeInterval = 60
    static let sleepThreshold: TimeInterval = 2
    static let minimumSpeedInterval: TimeInterval = 0.5
    /// 응답 시간을 보이는 최소 초당 작업 수
    static let minimumOperationsForLatency: Double = 10

    /// 날짜별·디스크별 누적 (오래된 날짜부터)
    private(set) var days: [DiskDayTotal]
    private(set) var hasUnsavedChanges = false

    private var previous: DiskSample?
    private var lastRates: [UInt64: DiskRates] = [:]

    init(days: [DiskDayTotal]) {
        self.days = days.sorted { $0.day < $1.day }
    }

    /// 그 날짜, 그 디스크의 누적 (아직 없으면 0)
    func total(on day: String, key: String) -> DiskDayTotal {
        days.first { $0.day == day && $0.key == key } ?? DiskDayTotal(day: day, key: key)
    }

    mutating func markSaved() {
        hasUnsavedChanges = false
    }

    /// 새로 읽은 카운터를 누적에 더하고, 디스크별 이번 구간 값을 돌려줘요. 값을 알 수 없는 디스크는 빠져요.
    mutating func add(_ sample: DiskSample, calendar: Calendar) -> [UInt64: DiskRates] {
        guard let previous else {
            self.previous = sample
            lastRates = [:]
            return lastRates
        }
        self.previous = sample

        let today = NetworkMeter.dayKey(for: sample.date, calendar: calendar)
        let dayBefore = NetworkMeter.dayKey(for: previous.date, calendar: calendar)
        let elapsed = Self.seconds(from: previous.monotonic, to: sample.monotonic)
        let awakeElapsed = Self.seconds(from: previous.awake, to: sample.awake)
        let slept = elapsed - awakeElapsed > Self.sleepThreshold
        let canMeasure = !slept && elapsed >= Self.minimumSpeedInterval
        let sameDay = dayBefore == today || (!slept && elapsed <= Self.shortBoundaryInterval)

        var rates: [UInt64: DiskRates] = [:]
        for (id, counter) in sample.counters {
            guard let old = previous.counters[id], let key = sample.keys[id],
                  counter.bytesRead >= old.bytesRead, counter.bytesWritten >= old.bytesWritten,
                  counter.operationsRead >= old.operationsRead, counter.operationsWritten >= old.operationsWritten,
                  counter.timeRead >= old.timeRead, counter.timeWritten >= old.timeWritten else {
                // 새 디스크이거나 카운터가 줄었어요(다시 꽂음). 이번에는 기준점만 잡아요.
                continue
            }
            let readBytes = counter.bytesRead - old.bytesRead
            let writtenBytes = counter.bytesWritten - old.bytesWritten
            if readBytes > 0 || writtenBytes > 0 {
                if sameDay {
                    addToDay(today, key: key, read: readBytes, written: writtenBytes)
                } else {
                    markGap(on: dayBefore, key: key)
                    markGap(on: today, key: key)
                }
            }
            guard canMeasure else { continue }
            let readOps = Double(counter.operationsRead - old.operationsRead)
            let writeOps = Double(counter.operationsWritten - old.operationsWritten)
            let readTime = Double(counter.timeRead - old.timeRead) / 1_000_000_000
            let writeTime = Double(counter.timeWritten - old.timeWritten) / 1_000_000_000
            rates[id] = DiskRates(
                read: Double(readBytes) / elapsed,
                write: Double(writtenBytes) / elapsed,
                readOperations: readOps / elapsed,
                writeOperations: writeOps / elapsed,
                queueDepth: (readTime + writeTime) / elapsed,
                readLatency: readOps / elapsed >= Self.minimumOperationsForLatency ? readTime / readOps : nil,
                writeLatency: writeOps / elapsed >= Self.minimumOperationsForLatency ? writeTime / writeOps : nil)
        }

        if !slept && elapsed < Self.minimumSpeedInterval {
            // 바로 앞에 잰 지 얼마 안 됐어요(날짜 경계 표본 등). 앞에 계산한 값을 그대로 써요.
            return lastRates.filter { sample.counters[$0.key] != nil }
        }
        lastRates = rates
        return rates
    }

    // MARK: - 날짜별 누적

    private mutating func ensureDay(_ day: String, key: String) {
        guard !days.contains(where: { $0.day == day && $0.key == key }) else { return }
        days.append(DiskDayTotal(day: day, key: key))
        days.sort { $0.day < $1.day }
        // 최근 keptDays개 날짜만 남겨요. 방금 넣은 날짜는 남겨요.
        let keptDays = Set(Set(days.map(\.day)).sorted().suffix(Self.keptDays)).union([day])
        days.removeAll { !keptDays.contains($0.day) }
        hasUnsavedChanges = true
    }

    private mutating func addToDay(_ day: String, key: String, read: UInt64, written: UInt64) {
        ensureDay(day, key: key)
        guard let index = days.firstIndex(where: { $0.day == day && $0.key == key }) else { return }
        days[index].read &+= read
        days[index].written &+= written
        hasUnsavedChanges = true
    }

    private mutating func markGap(on day: String, key: String) {
        ensureDay(day, key: key)
        guard let index = days.firstIndex(where: { $0.day == day && $0.key == key }) else { return }
        days[index].hasGap = true
        hasUnsavedChanges = true
    }

    private static func seconds(from start: UInt64, to end: UInt64) -> TimeInterval {
        end > start ? Double(end - start) / 1_000_000_000 : 0
    }
}
