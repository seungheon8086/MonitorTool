// 디스크 활성 시간 엔진 2: 장치 번호 → 물리 디스크. (docs/DISK_ACTIVE_TIME.md 1장)
// Diagnostics/DiskActiveProbe/Sources/DiskMap.swift에서 옮겼다. 도구만 쓰던 드라이버 통계(앱이 읽음)와 기기 이름은 뺐다.
// 물리 디스크 = 장치(IOMedia)에서 IORegistry를 위로 거슬러 올라가 처음 만나는 IOBlockStorageDriver.
// 앱의 디스크 항목(DiskDevice.id)과 같은 기준(IORegistry 항목 ID)이다. APFS 볼륨(disk3s5 등)은 위로 올라가면 disk0에 닿는다.
import Foundation
import IOKit

struct PhysicalDisk {
    let id: UInt64                  // IOBlockStorageDriver의 IORegistry 항목 ID
    let bsd: String                 // 디스크 전체의 BSD 이름 (disk0)
    let interconnect: String

    var isVirtual: Bool { interconnect == "Virtual Interface" }
}

struct MediaEntry {
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
                defer { IOObjectRelease(s) }
                let id = registryID(s)
                let protocolInfo = search(s, "Protocol Characteristics", parents: true) as? [String: Any] ?? [:]
                disks[id] = PhysicalDisk(
                    id: id,
                    bsd: (search(s, "BSD Name", parents: false) as? String) ?? "?",
                    interconnect: protocolInfo["Physical Interconnect"] as? String ?? "?")
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
                let entry = MediaEntry(disk: driverAbove(m))
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

    /// 디스크 구성이 바뀌었는지 싸게 보는 값: IOBlockStorageDriver와 IOMedia의 IORegistry 항목 ID (속성은 읽지 않는다).
    /// 디스크를 꽂거나 빼거나 디스크 이미지를 열면 바뀐다. 목록 전체를 다시 만드는 것보다 훨씬 싸다 (도구 4단계)
    static func signature() -> [UInt64] {
        var ids: [UInt64] = []
        for cls in ["IOBlockStorageDriver", "IOMedia"] {
            var it: io_iterator_t = 0
            guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(cls), &it) == KERN_SUCCESS else { continue }
            while true {
                let s = IOIteratorNext(it)
                if s == 0 { break }
                ids.append(registryID(s))
                IOObjectRelease(s)
            }
            IOObjectRelease(it)
        }
        return ids.sorted()
    }

    /// 내장 SSD (Apple Fabric으로 붙은 디스크). SSD 드라이버 이벤트는 이 디스크로 센다
    var internalSSD: UInt64? {
        disks.values.first { $0.interconnect == "Apple Fabric" }?.id
    }

    /// 물리 디스크 (디스크 이미지 빼고), BSD 이름 순 (disk2 < disk10)
    var physical: [PhysicalDisk] {
        disks.values.filter { !$0.isVirtual }.sorted { $0.bsd.localizedStandardCompare($1.bsd) == .orderedAscending }
    }

    /// 디스크가 아닌데 디스크 I/O 이벤트를 내는 장치: mm 장치(주번호 3: /dev/mem·kmem·null·zero)가
    /// cdevsw에서 D_DISK로 표시돼 있다 (dev/arm64/conf.c)
    static func isNonDisk(_ dev: Int32) -> Bool {
        (dev >> 24) & 0xff == 3
    }
}
