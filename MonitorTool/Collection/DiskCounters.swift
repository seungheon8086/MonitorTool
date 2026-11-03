import CryptoKit
import Foundation
import IOKit

/// 디스크 하나의 누적 카운터예요. 디스크가 연결된 뒤로 늘기만 해요. (IOBlockStorageDriver `Statistics`)
nonisolated struct DiskCounter: Hashable, Sendable {
    var bytesRead: UInt64 = 0
    var bytesWritten: UInt64 = 0
    var operationsRead: UInt64 = 0
    var operationsWritten: UInt64 = 0
    /// 읽기·쓰기에 걸린 시간의 합 (나노초)
    var timeRead: UInt64 = 0
    var timeWritten: UInt64 = 0
    var errorsRead: UInt64 = 0
    var errorsWritten: UInt64 = 0
    var retriesRead: UInt64 = 0
    var retriesWritten: UInt64 = 0

    /// `Statistics` 사전에서 읽어요. 바이트·작업 수·시간 중 하나라도 없으면 nil이에요.
    init?(statistics: [String: Any]) {
        func number(_ key: String) -> UInt64? {
            (statistics[key] as? NSNumber)?.uint64Value
        }
        guard let bytesRead = number("Bytes (Read)"), let bytesWritten = number("Bytes (Write)"),
              let operationsRead = number("Operations (Read)"), let operationsWritten = number("Operations (Write)"),
              let timeRead = number("Total Time (Read)"), let timeWritten = number("Total Time (Write)") else {
            return nil
        }
        self.bytesRead = bytesRead
        self.bytesWritten = bytesWritten
        self.operationsRead = operationsRead
        self.operationsWritten = operationsWritten
        self.timeRead = timeRead
        self.timeWritten = timeWritten
        errorsRead = number("Errors (Read)") ?? 0
        errorsWritten = number("Errors (Write)") ?? 0
        retriesRead = number("Retries (Read)") ?? 0
        retriesWritten = number("Retries (Write)") ?? 0
    }

    init() {}
}

/// 찾은 물리 디스크 하나예요.
nonisolated struct DiskDevice: Hashable, Sendable {
    /// IORegistry 항목 ID (IOBlockStorageDriver)
    var id: UInt64
    var bsdName: String
    /// 기기 이름 (Product Name)
    var model: String
    /// 연결 방식 (예: Apple Fabric, Secure Digital, USB, PCI-Express)
    var interconnect: String
    var isInternal: Bool
    /// 오늘 누적 저장용 고정 키
    var key: String
    /// NVMe SMART를 읽을 수 있는지 (`NVMe SMART Capable`)
    var smartCapable: Bool

    /// 보여줄 이름: 내장 SSD, SD 카드, 그 밖은 기기 이름 (없으면 BSD 이름)
    var displayName: String {
        if isInternal && interconnect == "Apple Fabric" {
            return "내장 SSD"
        }
        if interconnect == "Secure Digital" {
            return "SD 카드"
        }
        let trimmed = model.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? bsdName : trimmed
    }
}

/// IORegistry에서 물리 디스크를 찾고 카운터를 읽어요. 관리자 권한은 필요 없어요. (Diagnostics/DiskProbe)
/// 디스크 이미지(`Physical Interconnect` = `Virtual Interface`, 위치 `File`)는 뺍니다:
/// 이미지의 I/O는 그 파일이 있는 실제 디스크에도 같이 세어지기 때문이에요.
/// 매체가 없는 장치(카드를 꽂지 않은 SD 리더처럼 BSD 이름이 없는 것)도 뺍니다.
final class DiskRegistry {
    /// 찾은 디스크와 그 서비스 (서비스는 이 객체가 갖고 있다가 디스크가 빠지면 놓아요)
    private(set) var devices: [DiskDevice] = []
    private var services: [UInt64: io_service_t] = [:]
    /// SMART를 읽을 때 쓰는 부모 서비스 (IOEmbeddedNVMeBlockDevice 등)
    private var smartServices: [UInt64: io_service_t] = [:]

    /// 디스크 목록을 다시 훑어요. 실패하면 false예요(앞 목록은 그대로).
    @discardableResult
    func rescan() -> Bool {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"),
                                           &iterator) == KERN_SUCCESS else {
            return false
        }
        defer { IOObjectRelease(iterator) }

        var found: [DiskDevice] = []
        var foundIDs = Set<UInt64>()
        while true {
            let service = IOIteratorNext(iterator)
            if service == 0 { break }
            var entryID: UInt64 = 0
            guard IORegistryEntryGetRegistryEntryID(service, &entryID) == KERN_SUCCESS,
                  let device = Self.device(for: service, id: entryID) else {
                IOObjectRelease(service)
                continue
            }
            found.append(device)
            foundIDs.insert(entryID)
            if services[entryID] == nil {
                services[entryID] = service
                if device.smartCapable {
                    var parent: io_registry_entry_t = 0
                    if IORegistryEntryGetParentEntry(service, kIOServicePlane, &parent) == KERN_SUCCESS {
                        smartServices[entryID] = parent
                    }
                }
            } else {
                // 이미 갖고 있는 서비스예요.
                IOObjectRelease(service)
            }
        }
        // 빠진 디스크의 서비스는 놓아요.
        for (entryID, service) in services where !foundIDs.contains(entryID) {
            IOObjectRelease(service)
            services[entryID] = nil
            if let parent = smartServices.removeValue(forKey: entryID) {
                IOObjectRelease(parent)
            }
        }
        devices = found
        return true
    }

    /// 디스크 하나의 카운터. 읽지 못하면 nil이에요.
    func counter(for id: UInt64) -> DiskCounter? {
        guard let service = services[id],
              let statistics = IORegistryEntryCreateCFProperty(service, "Statistics" as CFString,
                                                               kCFAllocatorDefault, 0)?
                  .takeRetainedValue() as? [String: Any] else {
            return nil
        }
        return DiskCounter(statistics: statistics)
    }

    /// SMART를 읽을 서비스 (지원하지 않으면 nil)
    func smartService(for id: UInt64) -> io_service_t? {
        smartServices[id]
    }

    // MARK: - 디스크 정보

    private static func device(for service: io_service_t, id: UInt64) -> DiskDevice? {
        let parents = IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)
        let protocolInfo = search(service, "Protocol Characteristics", options: parents) as? [String: Any] ?? [:]
        let deviceInfo = search(service, "Device Characteristics", options: parents) as? [String: Any] ?? [:]
        let interconnect = protocolInfo["Physical Interconnect"] as? String ?? ""
        let location = protocolInfo["Physical Interconnect Location"] as? String ?? ""
        guard interconnect != "Virtual Interface", location != "File" else { return nil }
        // 매체가 있어야 BSD 이름(diskN)이 있어요.
        guard let bsdName = search(service, "BSD Name", options: IOOptionBits(kIORegistryIterateRecursively))
                as? String else {
            return nil
        }
        let model = (deviceInfo["Product Name"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        let serial = (deviceInfo["Serial Number"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        let smartCapable = number(search(service, "NVMe SMART Capable", options: parents)) != 0
        return DiskDevice(id: id,
                          bsdName: bsdName,
                          model: model,
                          interconnect: interconnect,
                          isInternal: location == "Internal",
                          key: stableKey(model: model, serial: serial, interconnect: interconnect, location: location),
                          smartCapable: smartCapable)
    }

    private static func search(_ service: io_service_t, _ key: String, options: IOOptionBits) -> Any? {
        IORegistryEntrySearchCFProperty(service, kIOServicePlane, key as CFString, kCFAllocatorDefault, options)
    }

    /// 참·거짓이나 숫자로 오는 값을 숫자로 (없으면 0)
    private static func number(_ value: Any?) -> Int {
        if let bool = value as? Bool {
            return bool ? 1 : 0
        }
        return (value as? NSNumber)?.intValue ?? 0
    }

    /// 앱을 다시 켜도, 디스크를 다시 꽂아도 같은 키예요. 일련번호는 해시로만 남겨요.
    private static func stableKey(model: String, serial: String, interconnect: String, location: String) -> String {
        let text = [model, serial, interconnect, location].joined(separator: "|")
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}
