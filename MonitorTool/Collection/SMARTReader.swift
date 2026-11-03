import Foundation
import IOKit

/// 디스크의 NVMe SMART 로그를 읽어요. 관리자 권한 없이 읽혀요. (Diagnostics/DiskProbe)
/// 플러그인은 디스크마다 한 번 열어 두고(5~8 ms) 다시 써요(한 번 읽기 0.4~1.4 ms).
final class SMARTReader {
    private var handles: [UInt64: OpaquePointer] = [:]

    /// 디스크 하나의 SMART를 읽어요.
    func read(id: UInt64, service: io_service_t) -> Result<SMARTInfo, SMARTError> {
        let handle: OpaquePointer
        if let opened = handles[id] {
            handle = opened
        } else {
            var error: Int32 = 0
            guard let opened = MTSMARTOpen(service, &error) else {
                return .failure(SMARTError(code: error))
            }
            handles[id] = opened
            handle = opened
        }
        var buffer = [UInt8](repeating: 0, count: 512)
        let result = buffer.withUnsafeMutableBufferPointer { pointer in
            MTSMARTRead(handle, pointer.baseAddress)
        }
        guard result == 0 else {
            // 다음에는 새로 열어 봐요.
            close(id: id)
            return .failure(SMARTError(code: result))
        }
        return .success(Self.parse(buffer))
    }

    /// 빠진 디스크의 플러그인을 닫아요.
    func keepOnly(_ ids: Set<UInt64>) {
        for id in handles.keys where !ids.contains(id) {
            close(id: id)
        }
    }

    private func close(id: UInt64) {
        if let handle = handles.removeValue(forKey: id) {
            MTSMARTClose(handle)
        }
    }

    /// NVMe 규격의 SMART 로그 위치대로 풀어요. 128비트 카운터는 아래 64비트만 써요.
    nonisolated static func parse(_ bytes: [UInt8]) -> SMARTInfo {
        func little(_ offset: Int, _ length: Int) -> UInt64 {
            var value: UInt64 = 0
            for index in stride(from: offset + length - 1, through: offset, by: -1) {
                value = value << 8 | UInt64(bytes[index])
            }
            return value
        }
        func counter(_ index: Int) -> UInt64 {
            little(32 + 16 * index, 8)
        }
        let unit = 512_000.0
        return SMARTInfo(criticalWarning: bytes[0],
                         percentageUsed: Int(bytes[5]),
                         availableSpare: Int(bytes[3]),
                         spareThreshold: Int(bytes[4]),
                         totalRead: Double(counter(0)) * unit,
                         totalWritten: Double(counter(1)) * unit,
                         powerOnHours: counter(6),
                         powerCycles: counter(5),
                         unsafeShutdowns: counter(7),
                         mediaErrors: counter(8),
                         errorLogEntries: counter(9),
                         warningTemperatureMinutes: UInt32(little(192, 4)),
                         criticalTemperatureMinutes: UInt32(little(196, 4)))
    }
}

/// SMART를 읽지 못한 이유 코드
nonisolated struct SMARTError: Error {
    var code: Int32
}
