import Foundation
import IOKit

// 보조 프로그램이 팬 제어에 쓰는 AppleSMC 연결이에요.
// 읽기(5)·키 정보(9) 명령은 앱의 SMC.swift와 같고, 쓰기(6) 명령은 여기에만 있어요.
// 쓰기는 관리자 권한이 있어야 받아들여져요. (Diagnostics/FanProbe: 권한 없이 쓰면 0xe00002c1)
// 구조체 배치는 앱의 SMC.swift·SensorProbe·FanProbe와 같아요. (80바이트, keyInfo 뒤 UInt16 빈칸)

struct HelperSMCVersion {
    var major: UInt8 = 0
    var minor: UInt8 = 0
    var build: UInt8 = 0
    var reserved: UInt8 = 0
    var release: UInt16 = 0
}

struct HelperSMCPLimitData {
    var version: UInt16 = 0
    var length: UInt16 = 0
    var cpuPLimit: UInt32 = 0
    var gpuPLimit: UInt32 = 0
    var memPLimit: UInt32 = 0
}

struct HelperSMCKeyInfo {
    var dataSize: UInt32 = 0
    var dataType: UInt32 = 0
    var dataAttributes: UInt8 = 0
}

typealias HelperSMCBytes = (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)

struct HelperSMCKeyData {
    var key: UInt32 = 0
    var version = HelperSMCVersion()
    var pLimitData = HelperSMCPLimitData()
    var keyInfo = HelperSMCKeyInfo()
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: HelperSMCBytes = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                                 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
}

/// SMC 쓰기가 실패한 이유 (패널에 보일 문구에 들어가요)
enum HelperSMCError: Error {
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

/// AppleSMC 연결이에요. FanController의 queue 안에서만 써요.
final class HelperSMC {
    private var connection: io_connect_t = 0
    /// 키마다 크기와 형식은 바뀌지 않아서 한 번 물어본 것을 기억해요. (없는 키는 nil로 기억)
    private var keyInfos: [String: HelperSMCKeyInfo?] = [:]

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

    /// 키 값을 숫자로 읽어요. 없는 키이거나 읽지 못하면 nil이에요.
    func number(_ key: String) -> Double? {
        guard let info = info(for: key) else {
            return nil
        }
        var request = HelperSMCKeyData()
        request.key = HelperSMC.fourCC(key)
        request.keyInfo.dataSize = info.dataSize
        request.data8 = 5 // 읽기 (kSMCReadKey)
        guard case .success(let output) = call(request) else {
            return nil
        }
        let size = Int(min(info.dataSize, 32))
        let bytes = withUnsafeBytes(of: output.bytes) { Array($0.prefix(size)) }
        return HelperSMC.decode(type: HelperSMC.fourCCString(info.dataType), bytes: bytes)
    }

    /// 키의 형식에 맞춰 숫자를 써요. 팬 키가 쓰는 flt·ui8만 다뤄요.
    func write(_ key: String, _ value: Double) -> Result<Void, HelperSMCError> {
        guard let info = info(for: key) else {
            return .failure(.missingKey(key))
        }
        guard let encoded = HelperSMC.encode(value, type: HelperSMC.fourCCString(info.dataType),
                                             size: Int(info.dataSize)) else {
            return .failure(.unsupportedType(key))
        }
        var request = HelperSMCKeyData()
        request.key = HelperSMC.fourCC(key)
        request.keyInfo.dataSize = info.dataSize
        request.data8 = 6 // 쓰기 (kSMCWriteKey)
        withUnsafeMutableBytes(of: &request.bytes) { raw in
            for (index, byte) in encoded.enumerated() where index < raw.count {
                raw[index] = byte
            }
        }
        return call(request).map { _ in () }
    }

    private func info(for key: String) -> HelperSMCKeyInfo? {
        if let known = keyInfos[key] {
            return known
        }
        var request = HelperSMCKeyData()
        request.key = HelperSMC.fourCC(key)
        request.data8 = 9 // 키 정보 (kSMCGetKeyInfo)
        let found: HelperSMCKeyInfo?
        if case .success(let output) = call(request) {
            found = output.keyInfo
        } else {
            found = nil
        }
        keyInfos[key] = .some(found)
        return found
    }

    private func call(_ request: HelperSMCKeyData) -> Result<HelperSMCKeyData, HelperSMCError> {
        guard connection != 0 else {
            return .failure(.notOpen)
        }
        var input = request
        var output = HelperSMCKeyData()
        var outputSize = MemoryLayout<HelperSMCKeyData>.stride
        let result = IOConnectCallStructMethod(connection, 2, &input, MemoryLayout<HelperSMCKeyData>.stride,
                                               &output, &outputSize)
        guard result == KERN_SUCCESS else {
            return .failure(.call(result))
        }
        guard output.result == 0 else {
            return .failure(.smc(output.result))
        }
        return .success(output)
    }

    // MARK: - 값 변환

    static func fourCC(_ text: String) -> UInt32 {
        text.utf8.prefix(4).reduce(0) { $0 << 8 | UInt32($1) }
    }

    static func fourCCString(_ value: UInt32) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((value >> UInt32($0)) & 0xFF) }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Apple Silicon의 flt는 리틀 엔디언, 정수 형식은 빅 엔디언이에요.
    static func decode(type: String, bytes: [UInt8]) -> Double? {
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
            guard bytes.count >= 2 else {
                return nil
            }
            return Double((UInt16(bytes[0]) << 8) | UInt16(bytes[1]))
        case "sp78":
            guard bytes.count >= 2 else {
                return nil
            }
            return Double(Int16(bitPattern: (UInt16(bytes[0]) << 8) | UInt16(bytes[1]))) / 256
        default:
            return nil
        }
    }

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
