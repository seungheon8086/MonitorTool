#if DEBUG
import Foundation

// Xcode 미리보기에서만 쓰는 예시 값이에요. 실제 앱(⌘R)에는 나오지 않아요.
// 숫자는 화면 시안과 같아요.

extension MonitorSnapshot {
    /// 모든 값이 정상인 예시
    nonisolated static var example: MonitorSnapshot {
        let now = Date()
        let gigabyte = 1_073_741_824.0
        var snapshot = MonitorSnapshot()
        snapshot.takenAt = now
        snapshot.helper = .enabled

        snapshot.cpu = CPUSnapshot(
            efficiencyUsage: .ok(34, at: now),
            performanceUsage: .ok(18, at: now),
            power: .ok(2.3, at: now),
            cores: [
                CoreUsage(id: 0, kind: .efficiency, cluster: 0, usage: 41),
                CoreUsage(id: 1, kind: .efficiency, cluster: 0, usage: 27),
                CoreUsage(id: 2, kind: .performance, cluster: 1, usage: 22),
                CoreUsage(id: 3, kind: .performance, cluster: 1, usage: 15),
                CoreUsage(id: 4, kind: .performance, cluster: 1, usage: 30),
                CoreUsage(id: 5, kind: .performance, cluster: 1, usage: 9),
                CoreUsage(id: 6, kind: .performance, cluster: 2, usage: 12),
                CoreUsage(id: 7, kind: .performance, cluster: 2, usage: 8),
                CoreUsage(id: 8, kind: .performance, cluster: 2, usage: 25),
                CoreUsage(id: 9, kind: .performance, cluster: 2, usage: 23),
            ])

        snapshot.ane.isActive = .ok(true, at: now)
        snapshot.ane.activeSince = now.addingTimeInterval(-24)
        snapshot.ane.power = .ok(1.4, at: now)
        snapshot.ane.dramTraffic = .ok(2.7e9, at: now)
        snapshot.ane.temperature = .ok(54, at: now)

        snapshot.gpu = GPUSnapshot(usage: .ok(9, at: now), power: .ok(0.4, at: now), memory: .ok(2.6 * gigabyte, at: now))

        snapshot.memory = MemorySnapshot(
            used: .ok(11.4 * gigabyte, at: now),
            total: .ok(16 * gigabyte, at: now),
            pressure: .ok(.normal, at: now),
            compressed: .ok(1.3 * gigabyte, at: now),
            swapUsed: .ok(0.4 * gigabyte, at: now),
            trafficTotal: .ok(9.8e9, at: now),
            trafficRead: .ok(6.1e9, at: now),
            trafficWrite: .ok(3.7e9, at: now),
            trafficByDevice: [
                DeviceTraffic(device: .cpu, bytesPerSecond: 3.6e9),
                DeviceTraffic(device: .gpu, bytesPerSecond: 1.9e9),
                DeviceTraffic(device: .ane, bytesPerSecond: 2.7e9),
                DeviceTraffic(device: .display, bytesPerSecond: 1.1e9),
                DeviceTraffic(device: .storage, bytesPerSecond: 0.2e9),
                DeviceTraffic(device: .other, bytesPerSecond: 0.3e9),
            ])

        snapshot.thermal = ThermalSnapshot(
            cpuMax: .ok(61, at: now),
            gpuMax: .ok(48, at: now),
            battery: .ok(32, at: now),
            ssd: .ok(35, at: now),
            fans: .ok([
                FanReading(id: 0, rpm: .ok(0, at: now), minimumRPM: 1499, maximumRPM: 4296, mode: .automatic),
                FanReading(id: 1, rpm: .ok(0, at: now), minimumRPM: 1499, maximumRPM: 4744, mode: .automatic),
            ], at: now))

        snapshot.battery = BatterySnapshot(
            level: .ok(76, at: now),
            chargeState: .ok(.discharging, at: now),
            netPower: .ok(-11.2, at: now),
            timeRemaining: .ok(4 * 3600 + 20 * 60, at: now),
            condition: .ok("정상", at: now),
            maximumCapacity: .ok(91, at: now),
            cycleCount: .ok(212, at: now))

        snapshot.network = NetworkSnapshot(
            download: .ok(1.8e6, at: now),
            upload: .ok(96e3, at: now),
            todayDownloaded: .ok(3.2e9, at: now),
            todayUploaded: .ok(410e6, at: now),
            todayDate: now,
            sessionDownloaded: .ok(820e6, at: now),
            sessionUploaded: .ok(96e6, at: now),
            sessionStartedAt: now.addingTimeInterval(-44 * 60),
            interfaces: [
                InterfaceRate(id: "en0", displayName: "Wi-Fi", download: 1.8e6, upload: 96e3),
            ])

        return snapshot
    }

    /// 보조 프로그램을 아직 허용하지 않은 예시 (CPU·ANE 전력이 '권한 필요')
    nonisolated static var exampleNeedsHelper: MonitorSnapshot {
        var snapshot = example
        snapshot.helper = .requiresApproval
        snapshot.cpu.power = .permissionNeeded
        snapshot.ane.power = .permissionNeeded
        snapshot.ane.isActive = .ok(false, at: snapshot.takenAt ?? Date())
        snapshot.ane.activeSince = nil
        snapshot.ane.temperature = .off
        snapshot.ane.dramTraffic = .ok(0, at: snapshot.takenAt ?? Date())
        return snapshot
    }

    /// 출처가 제때 새 값을 주지 않은 예시 (화면 시안 '값 상태 · 오래됨')
    /// CPU·ANE 전력은 보조 프로그램의 1초 표본이 12초째 오지 않았고, 배터리 순전력·사이클 수는 4분,
    /// 성능 상태·최대 용량은 2시간 전 값이에요. 실제 앱과 같은 기준(checkedFreshness)으로 '오래됨'을 붙여요.
    nonisolated static var exampleStale: MonitorSnapshot {
        var snapshot = example
        let now = snapshot.takenAt ?? Date()
        let powerAt = now.addingTimeInterval(-12)
        snapshot.cpu.power = Reading<Double>.ok(2.3, at: powerAt).checkedFreshness(now: now, limit: 4.5)
        snapshot.ane.power = Reading<Double>.ok(1.4, at: powerAt).checkedFreshness(now: now, limit: 4.5)
        let gaugeAt = now.addingTimeInterval(-4 * 60)
        snapshot.battery.netPower = Reading<Double>.ok(-11.2, at: gaugeAt).checkedFreshness(now: now, limit: 3 * 60)
        snapshot.battery.cycleCount = Reading<Int>.ok(212, at: gaugeAt).checkedFreshness(now: now, limit: 3 * 60)
        let healthAt = now.addingTimeInterval(-2 * 3600)
        snapshot.battery.condition = Reading<String>.ok("정상", at: healthAt).checkedFreshness(now: now, limit: 65 * 60)
        snapshot.battery.maximumCapacity = Reading<Double>.ok(91, at: healthAt).checkedFreshness(now: now, limit: 65 * 60)
        return snapshot
    }
}

extension MonitorStore {
    /// 모든 값이 정상이고 30분 기록이 있는 예시
    static var example: MonitorStore {
        let snapshot = MonitorSnapshot.example
        return MonitorStore(snapshot: snapshot,
                            history: .example(endingAt: snapshot.takenAt ?? Date()))
    }

    /// 보조 프로그램 허용 전 예시 (CPU·ANE 전력 기록이 비어 있어요)
    static var exampleNeedsHelper: MonitorStore {
        let snapshot = MonitorSnapshot.exampleNeedsHelper
        return MonitorStore(snapshot: snapshot,
                            history: .example(endingAt: snapshot.takenAt ?? Date(),
                                              helperAllowed: false, aneActive: false))
    }

    /// 오래된 값 예시 (그래프 기록은 정상 예시와 같아요)
    static var exampleStale: MonitorStore {
        let snapshot = MonitorSnapshot.exampleStale
        return MonitorStore(snapshot: snapshot,
                            history: .example(endingAt: snapshot.takenAt ?? Date()))
    }
}

extension MetricHistory {
    /// 미리보기용 30분 기록이에요. 마지막 값은 예시 화면 값과 같아요.
    /// 22분 전부터 2분 동안은 잠자기처럼 비워 둬서, 30분 그래프에서 선이 끊기는 모습도 볼 수 있어요.
    /// - Parameters:
    ///   - helperAllowed: false면 CPU·ANE 전력을 '권한 필요'(빈칸)로 남겨요.
    ///   - aneActive: true면 마지막 24초 동안 ANE가 일한 것으로 만들어요.
    nonisolated static func example(endingAt end: Date, helperAllowed: Bool = true,
                                    aneActive: Bool = true) -> MetricHistory {
        var history = MetricHistory()
        var noise = PreviewNoise(seed: 7)
        let count = Int(keepDuration)
        let gigabyte = 1_073_741_824.0

        for step in 0..<count {
            let secondsAgo = Double(count - 1 - step)
            // 22분 전 ~ 20분 전: 잠자기라서 기록이 없어요.
            if secondsAgo > 20 * 60 && secondsAgo <= 22 * 60 {
                continue
            }
            let date = end.addingTimeInterval(-secondsAgo)
            let isLast = step == count - 1
            let t = Double(step)

            /// 사인 곡선 + 잡음, low...high로 자른 값
            func wave(_ base: Double, _ amplitude: Double, _ period: Double,
                      _ low: Double, _ high: Double) -> Double {
                let value = base + sin(t / period) * amplitude * 0.6 + (noise.next() - 0.5) * amplitude
                return min(max(value, low), high)
            }

            /// 가운데가 center초 전인 종 모양 (0...1)
            func bump(center: Double, width: Double) -> Double {
                exp(-pow((secondsAgo - center) / width, 2))
            }

            let aneOn = aneActive && secondsAgo < 24
            let aneTraffic = aneOn ? (isLast ? 2.7e9 : wave(2.6e9, 1.0e9, 5, 0.3e9, 6e9))
                                   : wave(0.02e9, 0.02e9, 5, 0, 0.1e9)

            history.append(isLast ? 34 : wave(30, 22, 6, 2, 100), for: .cpuEfficiency, at: date)
            history.append(isLast ? 18 : wave(17, 14, 9, 1, 100), for: .cpuPerformance, at: date)
            history.append(helperAllowed ? (isLast ? 2.3 : wave(2.1, 1.4, 7, 0.4, 8)) : nil,
                           for: .cpuPower, at: date)
            history.append(isLast ? 9 : wave(10, 10, 5, 1, 100), for: .gpuUsage, at: date)
            history.append(isLast ? 0.4 : wave(0.5, 0.4, 6, 0.05, 4), for: .gpuPower, at: date)
            history.append((isLast ? 2.6 : wave(2.6, 0.3, 90, 2, 6)) * gigabyte, for: .gpuMemory, at: date)
            history.append(helperAllowed ? (aneOn ? (isLast ? 1.4 : wave(1.3, 0.5, 4, 0.2, 4)) : 0) : nil,
                           for: .anePower, at: date)
            history.append(aneTraffic, for: .aneTraffic, at: date)
            history.append((isLast ? 11.4 : wave(11.3, 0.3, 120, 10, 16)) * gigabyte, for: .memoryUsed, at: date)

            history.append(isLast ? 3.6e9 : wave(3.4e9, 1.6e9, 6, 0.5e9, 8e9), for: .traffic(.cpu), at: date)
            history.append(isLast ? 1.9e9 : wave(1.8e9, 0.8e9, 8, 0.2e9, 6e9), for: .traffic(.gpu), at: date)
            history.append(aneTraffic, for: .traffic(.ane), at: date)
            history.append(isLast ? 1.6e9 : wave(1.6e9, 0.4e9, 10, 0.4e9, 4e9), for: .traffic(.other), at: date)

            // 3분쯤 전에 CPU를 많이 써서 온도가 오르고 팬이 잠깐 돈 것처럼 만들어요.
            let cpuTemperature = 57 + 21 * bump(center: 180, width: 60) + (noise.next() - 0.5) * 3
            let gpuTemperature = 46 + 5 * bump(center: 170, width: 80) + (noise.next() - 0.5) * 1.5
            history.append(isLast ? 61 : cpuTemperature, for: .cpuTemperature, at: date)
            history.append(isLast ? 48 : gpuTemperature, for: .gpuTemperature, at: date)
            let fanSpinning = secondsAgo >= 120 && secondsAgo <= 240
            history.append(fanSpinning ? 1500 + 700 * bump(center: 180, width: 40) : 0, for: .fan(0), at: date)
            history.append(fanSpinning ? 1560 + 760 * bump(center: 180, width: 40) : 0, for: .fan(1), at: date)

            history.append(isLast ? -11.2 : wave(-11, 3, 7, -30, 30), for: .batteryNetPower, at: date)
            history.append(isLast ? 1.8e6 : wave(1.6e6, 1.6e6, 4, 0.05e6, 4e6), for: .networkDownload, at: date)
            history.append(isLast ? 96e3 : wave(0.1e6, 0.08e6, 6, 0.01e6, 4e6), for: .networkUpload, at: date)
        }
        return history
    }
}

/// 미리보기 기록용 잡음이에요. 시드가 같으면 늘 같은 값이 나와서 미리보기가 매번 같게 보여요.
nonisolated struct PreviewNoise {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    /// 0 이상 1 미만
    mutating func next() -> Double {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Double(state >> 11) / 9_007_199_254_740_992
    }
}
#endif
