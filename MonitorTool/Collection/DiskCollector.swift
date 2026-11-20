import Darwin
import Foundation
import IOKit

/// 날짜별·디스크별 누적을 저장해요. 같은 날 앱을 다시 켜면 이어서 세요.
/// 매초 저장하지 않고 30초마다, 잠들기 전, 앱을 끌 때 묶어서 저장해요. (설계 문서 4장)
final class DiskTotalsStore {
    private let defaults: UserDefaults
    private static let storageKey = "diskDailyTotals"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> [DiskDayTotal] {
        guard let data = defaults.data(forKey: DiskTotalsStore.storageKey),
              let saved = try? JSONDecoder().decode([DiskDayTotal].self, from: data) else {
            return []
        }
        return saved
    }

    func save(_ days: [DiskDayTotal]) {
        if let data = try? JSONEncoder().encode(days) {
            defaults.set(data, forKey: DiskTotalsStore.storageKey)
        }
    }
}

/// 물리 디스크별 I/O를 재서 패널 값으로 만들어요. (docs/DISK_IO.md)
/// 수집 일정(CollectionScheduler)이 패널이 열려 있으면 1초, 닫혀 있으면 10초마다 불러요.
final class DiskCollector {
    private let registry = DiskRegistry()
    private let smart = SMARTReader()
    private var meter: DiskMeter
    private let totalsStore: DiskTotalsStore
    private var savedAt = Date()
    /// 디스크 목록을 마지막으로 훑은 때 (잠든 시간도 세는 시계, 나노초. 0이면 아직)
    private var scannedAt: UInt64 = 0
    /// 디스크 목록을 읽지 못했는지
    private var scanFailed = false
    /// SMART 값과 마지막으로 읽은 때 (IORegistry 항목 ID별)
    private var smartReadings: [UInt64: Reading<SMARTInfo>] = [:]
    private var smartReadAt: [UInt64: Date] = [:]

    /// 디스크 목록을 다시 훑는 간격 (꽂고 빼기를 알아채는 데 걸리는 시간)
    private static let rescanInterval: UInt64 = 4_500_000_000
    private static let saveInterval: TimeInterval = 30
    /// SMART는 천천히 바뀌어서 1분마다 읽어요. 읽지 못했으면 10초 뒤 다시.
    private static let smartInterval: TimeInterval = 60
    private static let smartRetryInterval: TimeInterval = 10

    init(totalsStore: DiskTotalsStore = DiskTotalsStore()) {
        self.totalsStore = totalsStore
        meter = DiskMeter(days: totalsStore.load())
    }

    /// 카운터를 한 번 읽어 패널 값을 만들어요.
    func collect(now: Date = Date()) -> DiskSnapshot {
        let clock = clock_gettime_nsec_np(CLOCK_MONOTONIC)
        if scannedAt == 0 || clock &- scannedAt >= DiskCollector.rescanInterval {
            scannedAt = clock
            scanFailed = !registry.rescan()
        }
        if scanFailed && registry.devices.isEmpty {
            return DiskSnapshot(disks: .failed("디스크 목록을 읽지 못함"))
        }

        var counters: [UInt64: DiskCounter] = [:]
        var keys: [UInt64: String] = [:]
        for device in registry.devices {
            keys[device.id] = device.key
            counters[device.id] = registry.counter(for: device.id)
        }
        let sample = DiskSample(counters: counters,
                                keys: keys,
                                date: now,
                                monotonic: clock,
                                awake: clock_gettime_nsec_np(CLOCK_UPTIME_RAW))
        let rates = meter.add(sample, calendar: Calendar.current)
        if meter.hasUnsavedChanges, now.timeIntervalSince(savedAt) >= DiskCollector.saveInterval {
            save()
        }
        updateSMART(now: now)

        let day = NetworkMeter.dayKey(for: now, calendar: Calendar.current)
        let disks = registry.devices
            .map { device in
                makeReading(device, counter: counters[device.id], rates: rates[device.id],
                            today: meter.total(on: day, key: device.key), now: now)
            }
            .sorted { lhs, rhs in
                if lhs.isInternal != rhs.isInternal {
                    return lhs.isInternal
                }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
        return DiskSnapshot(disks: .ok(Self.uniquelyNamed(disks), at: now))
    }

    /// 디스크별 지금까지의 작업 수 (읽기+쓰기 누적)예요. 보조 프로그램의 활성 누적값을 받은 순간 읽어서
    /// 그 작업 수와 대조해요. 디스크 하나에 20~90 µs. (docs/DISK_ACTIVE_TIME.md 4.2)
    func operationCounts() -> [UInt64: UInt64] {
        var counts: [UInt64: UInt64] = [:]
        for device in registry.devices {
            if let counter = registry.counter(for: device.id) {
                counts[device.id] = counter.operationsRead &+ counter.operationsWritten
            }
        }
        return counts
    }

    /// 지금까지의 날짜별 누적을 바로 저장해요. (잠들기 전, 앱을 끌 때)
    func save() {
        totalsStore.save(meter.days)
        meter.markSaved()
        savedAt = Date()
    }

    // MARK: - 패널 값 만들기

    private func makeReading(_ device: DiskDevice, counter: DiskCounter?, rates: DiskRates?,
                             today: DiskDayTotal, now: Date) -> DiskReading {
        var reading = DiskReading(id: device.id,
                                  key: device.key,
                                  name: device.displayName,
                                  model: device.model.isEmpty ? device.bsdName : device.model,
                                  bsdName: device.bsdName,
                                  isInternal: device.isInternal)
        reading.todayDate = now
        reading.todayRead = .ok(Double(today.read), at: now)
        reading.todayWritten = .ok(Double(today.written), at: now)
        reading.todayHasGap = today.hasGap
        reading.smart = device.smartCapable ? (smartReadings[device.id] ?? .preparing) : nil

        guard let counter else {
            // 이번에 카운터를 읽지 못했어요.
            let failed = Reading<Double>.failed("디스크 통계를 읽지 못함")
            reading.read = failed
            reading.write = failed
            reading.queueDepth = failed
            reading.readLatency = failed
            reading.writeLatency = failed
            reading.readOperations = failed
            reading.writeOperations = failed
            return reading
        }
        reading.readErrors = counter.errorsRead
        reading.writeErrors = counter.errorsWritten
        reading.readRetries = counter.retriesRead
        reading.writeRetries = counter.retriesWritten

        guard let rates else {
            // 첫 표본·다시 꽂은 직후·깨어난 직후: 다음 표본부터 알 수 있어요.
            return reading
        }
        reading.read = Self.reading(rates.read, at: now)
        reading.write = Self.reading(rates.write, at: now)
        reading.queueDepth = Self.reading(rates.queueDepth, at: now)
        reading.readOperations = Self.reading(rates.readOperations, at: now)
        reading.writeOperations = Self.reading(rates.writeOperations, at: now)
        reading.readLatency = rates.readLatency.map { Self.reading($0, at: now) } ?? .notMeasurable("작업 적음")
        reading.writeLatency = rates.writeLatency.map { Self.reading($0, at: now) } ?? .notMeasurable("작업 적음")
        return reading
    }

    private static func reading(_ value: Double, at date: Date) -> Reading<Double> {
        guard value.isFinite, value >= 0 else { return .failed("계산할 수 없는 값") }
        return .ok(value, at: date)
    }

    /// 이름이 겹치는 디스크는 뒤에 BSD 이름을 붙여요. (예: 같은 외장 SSD 두 개)
    private static func uniquelyNamed(_ disks: [DiskReading]) -> [DiskReading] {
        var counts: [String: Int] = [:]
        for disk in disks {
            counts[disk.name, default: 0] += 1
        }
        return disks.map { disk in
            var disk = disk
            if counts[disk.name, default: 0] > 1 {
                disk.name = "\(disk.name) (\(disk.bsdName))"
            }
            return disk
        }
    }

    // MARK: - SMART

    /// SMART를 지원하는 디스크를 1분마다 읽어요. 빠진 디스크의 값은 지워요.
    private func updateSMART(now: Date) {
        let capable = registry.devices.filter(\.smartCapable)
        let ids = Set(capable.map(\.id))
        smart.keepOnly(ids)
        smartReadings = smartReadings.filter { ids.contains($0.key) }
        smartReadAt = smartReadAt.filter { ids.contains($0.key) }

        for device in capable {
            let interval: TimeInterval
            if case .failed = smartReadings[device.id]?.state {
                interval = DiskCollector.smartRetryInterval
            } else {
                interval = DiskCollector.smartInterval
            }
            if let readAt = smartReadAt[device.id], now.timeIntervalSince(readAt) < interval, readAt <= now {
                continue
            }
            smartReadAt[device.id] = now
            guard let service = registry.smartService(for: device.id) else {
                smartReadings[device.id] = .failed("SMART 장치를 찾지 못함")
                continue
            }
            switch smart.read(id: device.id, service: service) {
            case .success(let info):
                smartReadings[device.id] = .ok(info, at: now)
            case .failure(let error):
                AppLog.error(.disk, "SMART(\(device.bsdName)): 읽기 실패 0x\(String(UInt32(bitPattern: error.code), radix: 16))")
                smartReadings[device.id] = .failed("SMART를 읽지 못함")
            }
        }
    }
}
