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

        snapshot.gpu = GPUSnapshot(usage: .ok(9, at: now), power: .ok(0.4, at: now))

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
}

extension MonitorStore {
    static var example: MonitorStore {
        MonitorStore(snapshot: .example)
    }

    static var exampleNeedsHelper: MonitorStore {
        MonitorStore(snapshot: .exampleNeedsHelper)
    }
}
#endif
