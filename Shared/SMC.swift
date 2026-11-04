import Darwin
import Foundation
import IOKit

// AppleSMC 연결이에요. 앱(온도·팬 읽기)과 보조 프로그램(팬 쓰기)이 함께 써요.
// 읽기(5)·키 정보(9) 명령은 관리자 권한 없이 되고, 쓰기(6) 명령은 관리자 권한이 있어야 받아들여져요.
// (Diagnostics/FanProbe: 권한 없이 쓰면 0xe00002c1이라 쓰기는 보조 프로그램만 해요)
// 구조체 배치는 Stats(MIT)의 방식을 따랐고, Diagnostics/SensorProbe·FanProbe로 이 Mac에서 확인했어요.

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

/// SMC 요청이 실패한 이유 (보조 프로그램이 팬 제어 문구에 써요)
nonisolated enum SMCError: Error {
    case notOpen
    case missingKey(String)
    case unsupportedType(String)
    case call(kern_return_t)
    case smc(UInt8)

    var text: String {
        switch self {
        case .notOpen: "SMC 연결 실패"
        case .missingKey(let key): "SMC 키 없음 (\(key))"
        case .unsupportedType(let key): "SMC 형식 불일치 (\(key))"
        case .call(let code): "SMC 호출 오류 0x\(String(UInt32(bitPattern: code), radix: 16))"
        case .smc(let code): "SMC 오류 0x\(String(code, radix: 16))"
        }
    }
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

    /// 숫자를 형식에 맞는 바이트로 바꿔요. 팬 키가 쓰는 flt·ui8만 다뤄요.
    static func encode(_ value: Double, type: String, size: Int) -> [UInt8]? {
        switch type {
        case "flt ":
            guard size == 4, value.isFinite else {
                return nil
            }
            let bits = Float(value).bitPattern
            return [UInt8(bits & 0xFF), UInt8((bits >> 8) & 0xFF), UInt8((bits >> 16) & 0xFF), UInt8((bits >> 24) & 0xFF)]
        case "ui8 ":
            guard size == 1, value >= 0, value <= 255 else {
                return nil
            }
            return [UInt8(value)]
        default:
            return nil
        }
    }
}

/// AppleSMC 연결이에요. 한 곳에서만 써요. (앱은 메인 스레드, 보조 프로그램은 FanController의 queue)
nonisolated final class SMC {
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
        guard case .success(let output) = call(request) else {
            return nil
        }
        let size = Int(min(info.dataSize, 32))
        let bytes = withUnsafeBytes(of: output.bytes) { Array($0.prefix(size)) }
        return SMCCodec.number(type: SMCCodec.fourCCString(info.dataType), bytes: bytes)
    }

    /// 키의 형식에 맞춰 숫자를 써요. 관리자 권한이 있어야 해요. (보조 프로그램의 팬 제어만 써요)
    func write(_ key: String, _ value: Double) -> Result<Void, SMCError> {
        guard let info = info(for: key) else {
            return .failure(.missingKey(key))
        }
        guard let encoded = SMCCodec.encode(value, type: SMCCodec.fourCCString(info.dataType),
                                            size: Int(info.dataSize)) else {
            return .failure(.unsupportedType(key))
        }
        var request = SMCKeyData()
        request.key = SMCCodec.fourCC(key)
        request.keyInfo.dataSize = info.dataSize
        request.data8 = 6 // 쓰기 (kSMCWriteKey)
        withUnsafeMutableBytes(of: &request.bytes) { raw in
            for (index, byte) in encoded.enumerated() where index < raw.count {
                raw[index] = byte
            }
        }
        return call(request).map { _ in () }
    }

    private func info(for key: String) -> SMCKeyInfo? {
        if let known = keyInfos[key] {
            return known
        }
        var request = SMCKeyData()
        request.key = SMCCodec.fourCC(key)
        request.data8 = 9 // 키 정보 (kSMCGetKeyInfo)
        let found: SMCKeyInfo?
        if case .success(let output) = call(request) {
            found = output.keyInfo
        } else {
            found = nil
        }
        keyInfos[key] = .some(found)
        return found
    }

    /// SMC에 요청을 보내요. 연결 오류이거나 SMC가 오류 코드(예: 132 = 키 없음)를 돌려주면 실패예요.
    private func call(_ request: SMCKeyData) -> Result<SMCKeyData, SMCError> {
        guard connection != 0 else {
            return .failure(.notOpen)
        }
        var input = request
        var output = SMCKeyData()
        var outputSize = MemoryLayout<SMCKeyData>.stride
        let result = IOConnectCallStructMethod(connection, 2, &input, MemoryLayout<SMCKeyData>.stride,
                                               &output, &outputSize)
        guard result == KERN_SUCCESS else {
            return .failure(.call(result))
        }
        guard output.result == 0 else {
            return .failure(.smc(output.result))
        }
        return .success(output)
    }
}
