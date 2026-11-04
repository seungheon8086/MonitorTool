// DiskActiveProbe 엔진 조각 2: 장치 번호 → 물리 디스크, IOBlockStorageDriver 통계.
// 물리 디스크 = 장치(IOMedia)에서 IORegistry를 위로 거슬러 올라가 처음 만나는 IOBlockStorageDriver.
// 디스크 항목이 디스크를 구분하는 기준(IORegistry 항목 ID)과 같다. APFS 볼륨(disk3s5 등)은 위로 올라가면 disk0에 닿는다.
import Foundation
import IOKit

struct PhysicalDisk {
    let id: UInt64                  // IOBlockStorageDriver의 IORegistry 항목 ID
    let service: io_registry_entry_t
    let bsd: String                 // 디스크 전체의 BSD 이름 (disk0)
    let name: String                // 기기 이름
    let interconnect: String
    let location: String

    var isVirtual: Bool { interconnect == "Virtual Interface" }
}

struct DriverStats {
    var bytesRead: UInt64 = 0
    var bytesWritten: UInt64 = 0
    var opsRead: UInt64 = 0
    var opsWritten: UInt64 = 0
    var timeRead: UInt64 = 0        // 걸린 시간 합 (ns)
    var timeWritten: UInt64 = 0

    var bytes: UInt64 { bytesRead + bytesWritten }
    var ops: UInt64 { opsRead + opsWritten }
    var time: UInt64 { timeRead + timeWritten }
}

struct MediaEntry {
    let bsd: String
    let disk: UInt64?               // nil이면 위로 올라가도 IOBlockStorageDriver가 없음
}

private func property(_ s: io_registry_entry_t, _ key: String) -> Any? {
    IORegistryEntryCreateCFProperty(s, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
}

private func search(_ s: io_registry_entry_t, _ key: String, parents: Bool) -> Any? {
    var options = IOOptionBits(kIORegistryIterateRecursively)
    if parents { options |= IOOptionBits(kIORegistryIterateParents) }
    return IORegistryEntrySearchCFProperty(s, kIOServicePlane, key as CFString, kCFAllocatorDefault, options)
}

private func registryID(_ s: io_registry_entry_t) -> UInt64 {
    var id: UInt64 = 0
    IORegistryEntryGetRegistryEntryID(s, &id)
    return id
}

/// 장치에서 위로 올라가 처음 만나는 IOBlockStorageDriver의 항목 ID
private func driverAbove(_ start: io_registry_entry_t) -> UInt64? {
    var current = start
    IOObjectRetain(current)
    defer { IOObjectRelease(current) }
    for _ in 0..<24 {
        if IOObjectConformsTo(current, "IOBlockStorageDriver") != 0 { return registryID(current) }
        var parent: io_registry_entry_t = 0
        if IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent) != KERN_SUCCESS { return nil }
        IOObjectRelease(current)
        current = parent
    }
    return nil
}

private func deviceNumber(_ path: String) -> Int32? {
    var st = stat()
    return stat(path, &st) == 0 ? st.st_rdev : nil
}

final class DiskMap {
    private(set) var disks: [UInt64: PhysicalDisk] = [:]
    /// 장치 번호(dev_t) → 장치. 블록 장치(/dev/diskN)와 원시 장치(/dev/rdiskN)를 모두 넣는다.
    private(set) var devices: [Int32: MediaEntry] = [:]

    init() {
        var it: io_iterator_t = 0
        if IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &it) == KERN_SUCCESS {
            while true {
                let s = IOIteratorNext(it)
                if s == 0 { break }
                let id = registryID(s)
                let protocolInfo = search(s, "Protocol Characteristics", parents: true) as? [String: Any] ?? [:]
                let deviceInfo = search(s, "Device Characteristics", parents: true) as? [String: Any] ?? [:]
                let name = (deviceInfo["Product Name"] as? String)?.trimmingCharacters(in: .whitespaces) ?? "?"
                disks[id] = PhysicalDisk(
                    id: id,
                    service: s,
                    bsd: (search(s, "BSD Name", parents: false) as? String) ?? "?",
                    name: name,
                    interconnect: protocolInfo["Physical Interconnect"] as? String ?? "?",
                    location: protocolInfo["Physical Interconnect Location"] as? String ?? "?")
            }
            IOObjectRelease(it)
        }

        it = 0
        if IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOMedia"), &it) == KERN_SUCCESS {
            while true {
                let m = IOIteratorNext(it)
                if m == 0 { break }
                defer { IOObjectRelease(m) }
                guard let bsd = property(m, "BSD Name") as? String else { continue }
                let entry = MediaEntry(bsd: bsd, disk: driverAbove(m))
                for path in ["/dev/\(bsd)", "/dev/r\(bsd)"] {
                    if let dev = deviceNumber(path) { devices[dev] = entry }
                }
                if let major = (property(m, "BSD Major") as? NSNumber)?.int32Value,
                   let minor = (property(m, "BSD Minor") as? NSNumber)?.int32Value {
                    let dev = (major << 24) | minor
                    if devices[dev] == nil { devices[dev] = entry }
                }
            }
            IOObjectRelease(it)
        }
    }

    deinit {
        for d in disks.values { IOObjectRelease(d.service) }
    }

    func stats(_ id: UInt64) -> DriverStats? {
        guard let d = disks[id],
              let dict = property(d.service, "Statistics") as? [String: Any] else { return nil }
        func value(_ key: String) -> UInt64 { (dict[key] as? NSNumber)?.uint64Value ?? 0 }
        return DriverStats(
            bytesRead: value("Bytes (Read)"),
            bytesWritten: value("Bytes (Write)"),
            opsRead: value("Operations (Read)"),
            opsWritten: value("Operations (Write)"),
            timeRead: value("Total Time (Read)"),
            timeWritten: value("Total Time (Write)"))
    }

    func allStats() -> [UInt64: DriverStats] {
        var out: [UInt64: DriverStats] = [:]
        for id in disks.keys {
            if let s = stats(id) { out[id] = s }
        }
        return out
    }
}
