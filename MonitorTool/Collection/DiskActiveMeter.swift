import Foundation

/// 디스크 하나의 활성 시간 값이에요. (docs/DISK_ACTIVE_TIME.md 3.2)
nonisolated struct DiskActiveValue: Hashable, Sendable {
    /// 0~100 %
    var percent: Double
    /// 이 값의 기준 시각 (추적 값은 보조 프로그램의 1초 경계)
    var date: Date
    /// 이 값이 걸친 구간 (초). '오래됨' 기준에 써요.
    var interval: TimeInterval
    /// 내장 SSD의 캐시 비우기·TRIM 이벤트를 받았는지 (거짓이면 디스크 I/O만)
    var flushTrim: Bool
}

/// 보조 프로그램의 답을 받은 순간의 시계들이에요.
nonisolated struct DiskActiveMoment: Hashable, Sendable {
    /// 벽시계
    var date: Date
    /// 깨어 있던 시간만 세는 시계 (ns, CLOCK_UPTIME_RAW = 보조 프로그램이 쓰는 mach_absolute_time)
    var awake: UInt64
    /// 잠든 시간도 세는 시계 (ns, CLOCK_MONOTONIC)
    var monotonic: UInt64
}

/// 보조 프로그램이 넘긴 누적값으로 디스크별 활성 %를 내고, 드라이버 통계와 대조해요. (docs/DISK_ACTIVE_TIME.md 3.2 · 4.2)
/// 화면·저장과 떨어뜨려 두어서 규칙만 따로 시험할 수 있어요. (DiskMeter·NetworkMeter와 같은 방식)
/// - 활성 % = 같은 회차 안에서 누적 차이 ÷ 경계 차이, 0~100%로 잘라요.
/// - 같은 경계를 다시 받으면 새 값이 아니에요. 앞 값을 그대로 두고 그래프에 더하지 않아요.
/// - 첫 답·회차가 바뀜·경계가 줄어듦·잠든 구간은 기준만 잡아요. 디스크 하나의 누적이 줄었거나 새로 보인 디스크도 그 디스크만.
///   그동안 화면은 추정이에요.
/// - 이벤트를 잃은 구간은 그 구간만 추적 값을 버려요(추정). 다음 구간부터 추적 값이에요.
/// - 대조: 디스크마다 5분 창. 그 창의 드라이버 작업 수(읽기+쓰기)가 1,000개 이상일 때만 견주고,
///   보조 프로그램의 작업 수와의 차이가 5% + 창 끝 몫보다 크면 어긋남이에요. 창 끝 몫 = 창의 시작과 끝에서
///   앱이 드라이버 통계를 읽은 그 한 구간의 작업 수 (보조 프로그램 값은 마지막 1초 경계 값이라 0~1초 앞서요).
///   어긋난 디스크는 추정으로 보이고, 다음 창이 맞으면 추적 값으로 돌아가요. 창은 같은 회차 안에서만 이어 가요.
nonisolated struct DiskActiveMeter {
    /// 대조 창 길이 (5분)
    static let windowNanoseconds: UInt64 = 300_000_000_000
    /// 이보다 작업이 적은 창은 견주지 않아요.
    static let minimumOperations: UInt64 = 1_000
    /// 작업 수 차이의 허용 비율 (창 끝 몫과 따로)
    static let tolerance = 0.05
    /// 받은 사이에 벽시계가 깨어 있던 시간보다 이만큼 더 갔으면 잠든 것으로 봐요.
    static let sleepThreshold: UInt64 = 2_000_000_000

    private struct Window {
        var generation: UInt64
        var startBoundary: UInt64
        var startTrace: UInt64
        var startDriver: UInt64
        /// 창이 시작한 구간의 드라이버 작업 수 (시각이 어긋날 수 있는 몫)
        var startSlack: UInt64
    }

    /// 앞에 받은 추적 답과, 그때 읽은 드라이버 작업 수·시계
    private var base: DiskActivitySample?
    private var baseDriver: [UInt64: UInt64] = [:]
    private var baseMoment: DiskActiveMoment?
    private var windows: [UInt64: Window] = [:]
    /// 디스크별 마지막 추적 값
    private var traced: [UInt64: DiskActiveValue] = [:]
    /// 대조가 어긋난 디스크
    private(set) var mismatched: Set<UInt64> = []

    /// 화면에 쓸 추적 값. 없거나 대조가 어긋났으면 nil이에요. (그때는 추정을 보여요)
    func tracedValue(for id: UInt64) -> DiskActiveValue? {
        mismatched.contains(id) ? nil : traced[id]
    }

    /// 추적을 못 쓰게 됐어요. (보조 프로그램이 꺼짐·설정에서 끔·화면이 꺼짐) 다음 추적 답부터 새 기준이에요.
    /// 대조가 어긋난 디스크는 기억해 둬요. (macOS 쪽 문제라 회차가 바뀌어도 다음 창이 맞을 때까지 추정)
    mutating func reset() {
        base = nil
        baseDriver = [:]
        baseMoment = nil
        windows = [:]
        traced = [:]
    }

    /// 보조 프로그램의 답을 받았어요. driverOps는 받은 순간 읽은 디스크별 드라이버 작업 수(읽기+쓰기 누적)예요.
    /// 새 추적 값(그래프에 더할 것)을 디스크별로 돌려줘요. 대조가 어긋난 디스크는 빠져요.
    mutating func receive(_ sample: DiskActivitySample, driverOps: [UInt64: UInt64],
                          at moment: DiskActiveMoment) -> [UInt64: DiskActiveValue] {
        guard sample.state == .tracing else {
            // 추적 중이 아니에요. (비켜줌·꺼짐·실패·잡는 중) 추정으로 보여요.
            reset()
            return [:]
        }
        guard let base, let baseMoment, base.generation == sample.generation,
              sample.boundary >= base.boundary else {
            // 첫 답·회차가 바뀜·경계가 줄어듦: 기준만 잡아요.
            start(sample, driverOps: driverOps, at: moment)
            return [:]
        }
        // 같은 경계를 다시 받았어요. 새 값이 아니라서 앞 값을 그대로 둬요.
        guard sample.boundary > base.boundary else { return [:] }
        let wall = Self.minus(moment.monotonic, baseMoment.monotonic)
        let awake = Self.minus(moment.awake, baseMoment.awake)
        guard wall <= awake + Self.sleepThreshold else {
            // 잠든 구간이 끼었어요. 기준만 다시 잡아요. (디스크 속도와 같은 규칙)
            start(sample, driverOps: driverOps, at: moment)
            return [:]
        }

        let span = sample.boundary - base.boundary
        let date = moment.date.addingTimeInterval(-Double(Self.minus(moment.awake, sample.boundary)) / 1e9)
        let lost = sample.lostEvents > base.lostEvents
        let previous = Dictionary(base.disks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var fresh: [UInt64: DiskActiveValue] = [:]
        for disk in sample.disks {
            guard let old = previous[disk.id], disk.activeNs >= old.activeNs, disk.operations >= old.operations else {
                // 새로 보인 디스크·누적이 줄어듦: 이 디스크는 기준만 잡아요.
                traced[disk.id] = nil
                windows[disk.id] = nil
                continue
            }
            guard !lost else {
                // 커널 버퍼가 넘쳐 이 구간 값이 모자라요. 이 구간만 추정이에요.
                traced[disk.id] = nil
                continue
            }
            let percent = min(max(Double(disk.activeNs - old.activeNs) / Double(span) * 100, 0), 100)
            let value = DiskActiveValue(percent: percent, date: date, interval: Double(span) / 1e9,
                                        flushTrim: sample.flushTrim)
            traced[disk.id] = value
            fresh[disk.id] = value
        }
        let ids = Set(sample.disks.map(\.id))
        traced = traced.filter { ids.contains($0.key) }
        mismatched.formIntersection(ids)
        if lost {
            // 잃은 구간이 낀 창은 보조 프로그램의 작업 수가 모자라서 견줄 수 없어요. 창을 새로 시작해요.
            windows = [:]
        } else {
            updateWindows(sample, driverOps: driverOps)
        }
        self.base = sample
        baseDriver = driverOps
        self.baseMoment = moment
        return fresh.filter { !mismatched.contains($0.key) }
    }

    /// 기준만 잡아요.
    private mutating func start(_ sample: DiskActivitySample, driverOps: [UInt64: UInt64], at moment: DiskActiveMoment) {
        base = sample
        baseDriver = driverOps
        baseMoment = moment
        windows = [:]
        traced = [:]
        mismatched.formIntersection(Set(sample.disks.map(\.id)))
    }

    /// 대조 창을 이어 가고, 5분이 찼으면 견줘요.
    private mutating func updateWindows(_ sample: DiskActivitySample, driverOps: [UInt64: UInt64]) {
        for disk in sample.disks {
            guard let ops = driverOps[disk.id], let previousOps = baseDriver[disk.id], ops >= previousOps else {
                // 드라이버 통계를 못 읽었거나 줄었어요. (다시 꽂음) 창을 새로 시작해요.
                windows[disk.id] = nil
                continue
            }
            // 이번에 받은 사이의 드라이버 작업 수 = 이 구간의 창 끝 몫
            let slack = ops - previousOps
            guard let window = windows[disk.id], window.generation == sample.generation,
                  disk.operations >= window.startTrace, ops >= window.startDriver else {
                windows[disk.id] = Window(generation: sample.generation, startBoundary: sample.boundary,
                                          startTrace: disk.operations, startDriver: ops, startSlack: slack)
                continue
            }
            guard sample.boundary - window.startBoundary >= Self.windowNanoseconds else { continue }
            let driverCount = ops - window.startDriver
            if driverCount >= Self.minimumOperations {
                let traceCount = disk.operations - window.startTrace
                let difference = traceCount > driverCount ? traceCount - driverCount : driverCount - traceCount
                let allowed = Double(driverCount) * Self.tolerance + Double(window.startSlack) + Double(slack)
                if Double(difference) > allowed {
                    mismatched.insert(disk.id)
                } else {
                    mismatched.remove(disk.id)
                }
            }
            windows[disk.id] = Window(generation: sample.generation, startBoundary: sample.boundary,
                                      startTrace: disk.operations, startDriver: ops, startSlack: slack)
        }
        let ids = Set(sample.disks.map(\.id))
        windows = windows.filter { ids.contains($0.key) }
    }

    /// 음수가 될 차이는 0으로 (UInt64 뺄셈이 넘치면 멈추므로)
    private static func minus(_ a: UInt64, _ b: UInt64) -> UInt64 {
        a >= b ? a - b : 0
    }
}
