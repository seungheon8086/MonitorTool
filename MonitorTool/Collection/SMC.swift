import Darwin
import Foundation
import IOKit

// AppleSMC에서 온도·팬 값을 읽기만 해요. 읽기(5)와 키 정보(9) 명령만 쓰고, 값을 바꾸는 명령은 보내지 않아요.
// 구조체 배치는 Stats(MIT)의 방식을 따랐고, Diagnostics/SensorProbe로 이 Mac에서 확인했어요.

nonisolated struct SMCVersion {
    var major: UInt8 = 0
    var minor: UInt8 = 0
    var build: UInt8 = 0
    var reserved: UInt8 = 0
    var release: UInt16 = 0
}

nonisolated struct SMCPLimitData {
    var version: UInt16 = 0
    var length: UInt16 = 0
    var cpuPLimit: UInt32 = 0
    var gpuPLimit: UInt32 = 0
    var memPLimit: UInt32 = 0
}

/// 키 하나의 크기와 형식 (예: 4바이트 'flt ')
nonisolated struct SMCKeyInfo {
    var dataSize: UInt32 = 0
    var dataType: UInt32 = 0
    var dataAttributes: UInt8 = 0
}

/// 값이 담기는 32바이트
typealias SMCBytes = (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                      UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                      UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                      UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)

/// AppleSMC와 주고받는 구조체예요. C 구조체와 같은 80바이트 배치가 되도록 keyInfo 뒤에 빈칸(padding)을 넣었어요.
nonisolated struct SMCKeyData {
    var key: UInt32 = 0
    var version = SMCVersion()
    var pLimitData = SMCPLimitData()
    var keyInfo = SMCKeyInfo()
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: SMCBytes = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                           0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
}

/// SMC 키 이름과 값을 바꾸는 규칙이에요.
nonisolated enum SMCCodec {
    /// 'Tp01' 같은 네 글자 이름을 숫자로
    static func fourCC(_ text: String) -> UInt32 {
        text.utf8.prefix(4).reduce(0) { $0 << 8 | UInt32($1) }
    }

    /// 숫자를 네 글자 이름으로 (형식 이름에 써요. 예: 'flt ')
    static func fourCCString(_ value: UInt32) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((value >> UInt32($0)) & 0xFF) }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// 형식에 맞춰 숫자로 바꿔요. Apple Silicon의 flt는 리틀 엔디언, 정수·고정소수점 형식은 빅 엔디언이에요.
    static func number(type: String, bytes: [UInt8]) -> Double? {
        func bigEndian(_ count: Int) -> UInt64? {
            guard bytes.count >= count else {
                return nil
            }
            return bytes.prefix(count).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        }
        switch type {
        case "flt ":
            guard bytes.count >= 4 else {
                return nil
            }
            let raw = UInt32(bytes[0]) | (UInt32(bytes[1]) << 8) | (UInt32(bytes[2]) << 16) | (UInt32(bytes[3]) << 24)
            return Double(Float(bitPattern: raw))
        case "ui8 ", "flag":
            return bytes.first.map { Double($0) }
        case "ui16":
            return bigEndian(2).map { Double($0) }
        case "ui32":
            return bigEndian(4).map { Double($0) }
        case "si8 ":
            return bytes.first.map { Double(Int8(bitPattern: $0)) }
        case "si16":
            return bigEndian(2).map { Double(Int16(truncatingIfNeeded: $0)) }
        case "sp78":
            return bigEndian(2).map { Double(Int16(truncatingIfNeeded: $0)) / 256 }
        case "fpe2":
            return bigEndian(2).map { Double($0) / 4 }
        default:
            return nil
        }
    }
}

/// AppleSMC 연결이에요. 앱이 켜져 있는 동안 하나를 계속 써요.
final class SMC {
    private var connection: io_connect_t = 0
    /// 키마다 크기와 형식은 바뀌지 않아서 한 번 물어본 것을 기억해요. (없는 키는 nil로 기억)
    private var keyInfos: [String: SMCKeyInfo?] = [:]

    /// AppleSMC를 찾지 못하거나 열지 못하면 nil이에요.
    init?() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else {
            return nil
        }
        defer { IOObjectRelease(service) }
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == KERN_SUCCESS else {
            return nil
        }
    }

    /// 이 Mac에 있는 키인지
    func hasKey(_ key: String) -> Bool {
        info(for: key) != nil
    }

    /// 키 값을 숫자로 읽어요. 없는 키이거나 읽지 못하면 nil이에요.
    func number(_ key: String) -> Double? {
        guard let info = info(for: key) else {
            return nil
        }
        var request = SMCKeyData()
        request.key = SMCCodec.fourCC(key)
        request.keyInfo.dataSize = info.dataSize
        request.data8 = 5 // 읽기 (kSMCReadKey)
        guard let output = call(request) else {
            return nil
        }
        let size = Int(min(info.dataSize, 32))
        let bytes = withUnsafeBytes(of: output.bytes) { Array($0.prefix(size)) }
        return SMCCodec.number(type: SMCCodec.fourCCString(info.dataType), bytes: bytes)
    }

    private func info(for key: String) -> SMCKeyInfo? {
        if let known = keyInfos[key] {
            return known
        }
        var request = SMCKeyData()
        request.key = SMCCodec.fourCC(key)
        request.data8 = 9 // 키 정보 (kSMCGetKeyInfo)
        let info = call(request)?.keyInfo
        keyInfos[key] = .some(info)
        return info
    }

    /// SMC에 요청을 보내요. 연결 오류이거나 SMC가 오류 코드(예: 132 = 키 없음)를 돌려주면 nil이에요.
    private func call(_ request: SMCKeyData) -> SMCKeyData? {
        var input = request
        var output = SMCKeyData()
        var outputSize = MemoryLayout<SMCKeyData>.stride
        let result = IOConnectCallStructMethod(connection, 2, &input, MemoryLayout<SMCKeyData>.stride,
                                               &output, &outputSize)
        guard result == KERN_SUCCESS, output.result == 0 else {
            return nil
        }
        return output
    }
}
