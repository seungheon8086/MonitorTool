// 팬 제어 진단 도구 (FanProbe)
//
// 이 Mac(M1 Pro, macOS 27)에서 앱의 보조 프로그램이 팬을 제어할 수 있는지 확인해요.
// 1) info: 팬 관련 SMC 키(F…)의 형식·크기·속성 바이트와 값, 시험 모드 키(Ftst)·M5식 모드 키(F0md)가 있는지
// 2) unpriv-write: 관리자 권한 없이 쓰기가 거절되는지 (지금 값을 그대로 다시 써서 값은 바뀌지 않아요)
// 3) control: 관리자 권한으로 수동 모드 전환 → 목표 RPM 2,500 → 3,500 → 2,000 → 시스템 제어로 복원하며 1초마다 기록
// 4) restore: 수동 모드(1)로 남은 팬과 켜진 Ftst를 시스템 제어로 되돌려요 (measure.sh가 끝날 때 항상 불러요)
//
// 안전장치: 목표 RPM은 팬의 최소~최대 안으로만, 속도를 올리는 쪽으로만 시험해요.
// CPU·GPU 온도가 95 °C를 넘거나 Control-C·종료 신호를 받으면 바로 시스템 제어로 되돌리고 끝나요.
// SMC 쓰기(6)는 control·restore·unpriv-write에서만, F…Md·F…Tg·Ftst 키에만 써요.
// 앱에 그대로 넣을 코드가 아니라 확인용이에요.
//
// 빌드와 실행:
//   swiftc -O -swift-version 5 fan_probe.swift -o fan_probe
//   ./fan_probe info
//   ./fan_probe unpriv-write
//   sudo ./fan_probe control
//   sudo ./fan_probe restore

import Darwin
import Foundation
import IOKit

// MARK: - 공통

func log(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

func out(_ message: String) {
    print(message)
    fflush(stdout)
}

func fmt(_ value: Double?, _ digits: Int = 0) -> String {
    guard let value else { return "-" }
    return String(format: "%.\(digits)f", value)
}

// MARK: - SMC (SensorProbe와 같은 배치 + 쓰기)

struct SMCVersion {
    var major: UInt8 = 0
    var minor: UInt8 = 0
    var build: UInt8 = 0
    var reserved: UInt8 = 0
    var release: UInt16 = 0
}

struct SMCPLimitData {
    var version: UInt16 = 0
    var length: UInt16 = 0
    var cpuPLimit: UInt32 = 0
    var gpuPLimit: UInt32 = 0
    var memPLimit: UInt32 = 0
}

struct SMCKeyInfo {
    var dataSize: UInt32 = 0
    var dataType: UInt32 = 0
    var dataAttributes: UInt8 = 0
}

typealias SMCBytes = (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                      UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                      UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                      UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)

/// AppleSMC와 주고받는 80바이트 구조체 (keyInfo 뒤 UInt16 빈칸)
struct SMCKeyData {
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

enum SMCError: Error {
    /// IOKit 호출 자체가 실패 (권한 거절이면 보통 kIOReturnNotPrivileged 0xe00002c1)
    case call(kern_return_t)
    /// SMC가 오류 코드를 돌려줌 (132 = 키 없음, 0x82 등)
    case smc(UInt8)
    /// 값을 그 형식으로 바꿀 수 없음
    case encode(String)

    var text: String {
        switch self {
        case .call(let code):
            return "IOKit 오류 \(code) (0x\(String(UInt32(bitPattern: code), radix: 16)))"
        case .smc(let code):
            return "SMC 오류 \(code) (0x\(String(code, radix: 16)))"
        case .encode(let reason):
            return "값 변환 실패: \(reason)"
        }
    }
}

func fourCC(_ text: String) -> UInt32 {
    text.utf8.prefix(4).reduce(0) { $0 << 8 | UInt32($1) }
}

func fourCCString(_ value: UInt32) -> String {
    let bytes = [24, 16, 8, 0].map { UInt8((value >> $0) & 0xFF) }
    return String(decoding: bytes, as: UTF8.self)
}

/// Apple Silicon의 flt는 리틀 엔디언, 정수·고정소수점 형식은 빅 엔디언
func decodeSMC(type: String, bytes: [UInt8]) -> Double? {
    func bigEndian(_ count: Int) -> UInt64? {
        guard bytes.count >= count else { return nil }
        return bytes.prefix(count).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
    }
    switch type {
    case "flt ":
        guard bytes.count >= 4 else { return nil }
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

/// 숫자를 SMC 형식의 바이트로 바꿔요. 이 진단에 필요한 형식만 다뤄요.
func encodeSMC(_ value: Double, type: String, size: Int) -> [UInt8]? {
    switch type {
    case "flt ":
        guard size == 4, value.isFinite else { return nil }
        let bits = Float(value).bitPattern
        return [UInt8(bits & 0xFF), UInt8((bits >> 8) & 0xFF), UInt8((bits >> 16) & 0xFF), UInt8((bits >> 24) & 0xFF)]
    case "ui8 ", "flag":
        guard size == 1, value >= 0, value <= 255 else { return nil }
        return [UInt8(value)]
    case "ui16":
        guard size == 2, value >= 0, value <= 65535 else { return nil }
        let raw = UInt16(value)
        return [UInt8(raw >> 8), UInt8(raw & 0xFF)]
    case "fpe2":
        guard size == 2, value >= 0, value <= 16383 else { return nil }
        let raw = UInt16(value * 4)
        return [UInt8(raw >> 8), UInt8(raw & 0xFF)]
    default:
        return nil
    }
}

struct SMCValue {
    let type: String
    let size: Int
    let attributes: UInt8
    let bytes: [UInt8]

    var number: Double? { decodeSMC(type: type, bytes: bytes) }
    var hex: String { bytes.map { String(format: "%02x", $0) }.joined() }
}

final class SMC {
    private var connection: io_connect_t = 0

    init?() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else {
            log("AppleSMC를 찾지 못했어요.")
            return nil
        }
        defer { IOObjectRelease(service) }
        let result = IOServiceOpen(service, mach_task_self_, 0, &connection)
        guard result == KERN_SUCCESS else {
            log("AppleSMC를 열지 못했어요: \(result)")
            return nil
        }
    }

    deinit {
        IOServiceClose(connection)
    }

    private func call(_ request: SMCKeyData) -> Result<SMCKeyData, SMCError> {
        var input = request
        var output = SMCKeyData()
        var outputSize = MemoryLayout<SMCKeyData>.stride
        let result = IOConnectCallStructMethod(connection, 2, &input, MemoryLayout<SMCKeyData>.stride,
                                               &output, &outputSize)
        guard result == KERN_SUCCESS else { return .failure(.call(result)) }
        guard output.result == 0 else { return .failure(.smc(output.result)) }
        return .success(output)
    }

    func keyInfo(_ key: String) -> Result<SMCKeyInfo, SMCError> {
        var request = SMCKeyData()
        request.key = fourCC(key)
        request.data8 = 9   // kSMCGetKeyInfo
        return call(request).map { $0.keyInfo }
    }

    func hasKey(_ key: String) -> Bool {
        if case .success = keyInfo(key) { return true }
        return false
    }

    func read(_ key: String) -> Result<SMCValue, SMCError> {
        let info: SMCKeyInfo
        switch keyInfo(key) {
        case .success(let value): info = value
        case .failure(let error): return .failure(error)
        }
        var request = SMCKeyData()
        request.key = fourCC(key)
        request.keyInfo.dataSize = info.dataSize
        request.data8 = 5   // kSMCReadKey
        return call(request).map { output in
            let size = Int(min(info.dataSize, 32))
            let bytes = withUnsafeBytes(of: output.bytes) { Array($0.prefix(size)) }
            return SMCValue(type: fourCCString(info.dataType), size: Int(info.dataSize),
                            attributes: info.dataAttributes, bytes: bytes)
        }
    }

    func number(_ key: String) -> Double? {
        guard case .success(let value) = read(key) else { return nil }
        return value.number
    }

    /// 키의 형식에 맞춰 숫자를 써요.
    func write(_ key: String, _ value: Double) -> Result<Void, SMCError> {
        let info: SMCKeyInfo
        switch keyInfo(key) {
        case .success(let found): info = found
        case .failure(let error): return .failure(error)
        }
        let type = fourCCString(info.dataType)
        guard let encoded = encodeSMC(value, type: type, size: Int(info.dataSize)) else {
            return .failure(.encode("\(key) 형식 '\(type)' 크기 \(info.dataSize)에 \(value)"))
        }
        var request = SMCKeyData()
        request.key = fourCC(key)
        request.keyInfo.dataSize = info.dataSize
        request.data8 = 6   // kSMCWriteKey
        withUnsafeMutableBytes(of: &request.bytes) { raw in
            for (index, byte) in encoded.enumerated() where index < raw.count {
                raw[index] = byte
            }
        }
        return call(request).map { _ in () }
    }

    func key(at index: UInt32) -> String? {
        var request = SMCKeyData()
        request.data8 = 8   // kSMCGetKeyFromIndex
        request.data32 = index
        guard case .success(let output) = call(request) else { return nil }
        return fourCCString(output.key)
    }

    func allKeys() -> [String] {
        guard let count = number("#KEY") else {
            log("SMC 키 개수(#KEY)를 읽지 못했어요.")
            return []
        }
        return (0..<Int(count)).compactMap { key(at: UInt32($0)) }
    }
}

func describe(_ result: Result<Void, SMCError>) -> String {
    switch result {
    case .success: return "성공"
    case .failure(let error): return "실패 · \(error.text)"
    }
}

// MARK: - 팬·온도

let cpuTemperatureKeys = ["Tp01", "Tp05", "Tp09", "Tp0D", "Tp0H", "Tp0L", "Tp0P", "Tp0T", "Tp0X", "Tp0b"]
let gpuTemperatureKeys = ["Tg05", "Tg0D"]
let failsafeCelsius = 95.0

struct Fan {
    let index: Int
    let minimum: Double
    let maximum: Double
    var mode: String { "F\(index)Md" }
    var target: String { "F\(index)Tg" }
    var actual: String { "F\(index)Ac" }
}

func fans(_ smc: SMC) -> [Fan] {
    let count = Int(smc.number("FNum") ?? 0)
    return (0..<count).map { index in
        Fan(index: index,
            minimum: smc.number("F\(index)Mn") ?? 0,
            maximum: smc.number("F\(index)Mx") ?? 0)
    }
}

func highest(_ smc: SMC, _ keys: [String]) -> Double? {
    keys.compactMap { smc.number($0) }.filter { $0 > 0 }.max()
}

// MARK: - 신호 (Control-C 등)

/// 받은 신호 번호 (신호 처리기에서 바꿔요)
var stopSignal: Int32 = 0

func installSignalHandlers() {
    for sig in [SIGINT, SIGTERM, SIGHUP] {
        signal(sig) { received in stopSignal = received }
    }
}

// MARK: - info

func runInfo(_ smc: SMC) {
    out("# 팬 관련 SMC 키 (uid \(getuid()))")
    out("키\t형식\t크기\t속성\t값\t원본")
    let keys = smc.allKeys()
    out("# SMC 키 전체 \(keys.count)개")
    var listed = Set<String>()
    for key in keys where key.hasPrefix("F") {
        listed.insert(key)
        switch smc.read(key) {
        case .success(let value):
            let attributes = String(format: "0x%02x", value.attributes)
            out("\(key)\t\(value.type)\t\(value.size)\t\(attributes)\t\(fmt(value.number, 3))\t\(value.hex)")
        case .failure(let error):
            let info = smc.keyInfo(key)
            if case .success(let found) = info {
                out("\(key)\t\(fourCCString(found.dataType))\t\(found.dataSize)\t\(String(format: "0x%02x", found.dataAttributes))\t읽기 실패\t\(error.text)")
            } else {
                out("\(key)\t-\t-\t-\t읽기 실패\t\(error.text)")
            }
        }
    }
    out("# 비교용 (읽기 전용으로 알려진 키): FNum·F0Ac와 쓰기 대상 F0Md·F0Tg의 속성 바이트를 비교해요")
    for key in ["Ftst", "F0md", "FS! "] where !listed.contains(key) {
        out("# \(key): \(smc.hasKey(key) ? "있음" : "없음")")
    }
    if listed.contains("Ftst") {
        out("# Ftst: 있음 (목록 안)")
    }
}

// MARK: - unpriv-write

func runUnprivilegedWrite(_ smc: SMC) -> Int32 {
    guard getuid() != 0 else {
        log("이 단계는 관리자 권한 없이 실행해야 해요.")
        return 1
    }
    out("# 관리자 권한 없이 지금 값을 그대로 다시 쓰기 (값은 바뀌지 않아요)")
    for key in ["F0Md", "F0Tg"] {
        guard let current = smc.number(key) else {
            out("\(key)\t읽기 실패")
            continue
        }
        out("\(key)\t지금 값 \(fmt(current, 1))\t쓰기 \(describe(smc.write(key, current)))\t다시 읽은 값 \(fmt(smc.number(key), 1))")
    }
    return 0
}

// MARK: - restore

/// 수동 모드(1)인 팬을 0으로, 켜진 Ftst를 0으로 되돌려요. 되돌린 게 없으면 아무것도 쓰지 않아요.
@discardableResult
func restore(_ smc: SMC, reason: String) -> Bool {
    var ok = true
    var wrote = false
    for fan in fans(smc) {
        let mode = smc.number(fan.mode)
        if mode == 1 {
            let result = smc.write(fan.mode, 0)
            wrote = true
            if case .failure = result { ok = false }
            out("# 복원(\(reason)) \(fan.mode)=0 → \(describe(result)), 다시 읽은 값 \(fmt(smc.number(fan.mode)))")
        }
    }
    if smc.number("Ftst") == 1 {
        let result = smc.write("Ftst", 0)
        wrote = true
        if case .failure = result { ok = false }
        out("# 복원(\(reason)) Ftst=0 → \(describe(result))")
    }
    if !wrote {
        out("# 복원(\(reason)): 수동 모드인 팬이 없어 쓰지 않았어요. 모드: "
            + fans(smc).map { "\($0.mode)=\(fmt(smc.number($0.mode)))" }.joined(separator: " "))
    }
    return ok
}

// MARK: - control

struct Recorder {
    let smc: SMC
    let fanList: [Fan]
    let start = Date()

    func header() {
        var columns = ["초", "단계"]
        for fan in fanList {
            columns += ["F\(fan.index)Md", "F\(fan.index)Tg", "F\(fan.index)Ac"]
        }
        columns += ["CPU최고", "GPU최고", "Ftst"]
        out(columns.joined(separator: "\t"))
    }

    /// 1초마다 기록해요. 신호를 받았거나 너무 뜨거우면 false
    func sample(_ label: String, seconds: Int) -> Bool {
        for _ in 0..<seconds {
            for _ in 0..<4 {
                if stopSignal != 0 { return false }
                usleep(250_000)
            }
            var row = [fmt(Date().timeIntervalSince(start), 1), label]
            for fan in fanList {
                row += [fmt(smc.number(fan.mode)), fmt(smc.number(fan.target)), fmt(smc.number(fan.actual))]
            }
            let cpu = highest(smc, cpuTemperatureKeys)
            let gpu = highest(smc, gpuTemperatureKeys)
            row += [fmt(cpu, 1), fmt(gpu, 1), fmt(smc.number("Ftst"))]
            out(row.joined(separator: "\t"))
            if max(cpu ?? 0, gpu ?? 0) >= failsafeCelsius {
                out("# 온도가 \(Int(failsafeCelsius)) °C 이상이라 멈춰요")
                return false
            }
        }
        return true
    }
}

func setMode(_ smc: SMC, _ fanList: [Fan], manual: Bool) -> Bool {
    var all = true
    for fan in fanList {
        let result = smc.write(fan.mode, manual ? 1 : 0)
        out("# 쓰기 \(fan.mode)=\(manual ? 1 : 0) → \(describe(result)), 다시 읽은 값 \(fmt(smc.number(fan.mode)))")
        if case .failure = result { all = false }
    }
    return all
}

func setTarget(_ smc: SMC, _ fanList: [Fan], rpm: Double) {
    for fan in fanList {
        let clamped = min(max(rpm, fan.minimum), fan.maximum)
        let result = smc.write(fan.target, clamped)
        out("# 쓰기 \(fan.target)=\(fmt(clamped)) → \(describe(result)), 다시 읽은 값 \(fmt(smc.number(fan.target)))")
    }
}

func runControl(_ smc: SMC) -> Int32 {
    guard getuid() == 0 else {
        log("control은 관리자 권한(sudo)으로 실행해야 해요.")
        return 1
    }
    installSignalHandlers()
    let fanList = fans(smc)
    guard !fanList.isEmpty, fanList.allSatisfy({ $0.minimum > 0 && $0.maximum > $0.minimum }) else {
        out("# 팬 정보를 읽지 못해 시험하지 않아요: FNum=\(fmt(smc.number("FNum")))")
        return 1
    }
    out("# 팬 \(fanList.count)개: " + fanList.map { "F\($0.index) \(fmt($0.minimum))~\(fmt($0.maximum)) RPM" }.joined(separator: ", "))
    out("# Ftst \(smc.hasKey("Ftst") ? "있음" : "없음"), F0md \(smc.hasKey("F0md") ? "있음" : "없음")")
    let recorder = Recorder(smc: smc, fanList: fanList)
    recorder.header()

    var finished = false
    defer {
        restore(smc, reason: finished ? "시험 끝" : "중단")
    }

    guard recorder.sample("A-기준", seconds: 10) else { return 2 }

    // B: 수동 모드로. 거절되면 Ftst가 있을 때만 시험 모드를 켜고 다시 시도해요 (M3·M4 방식).
    var manual = setMode(smc, fanList, manual: true)
    if !manual, smc.hasKey("Ftst") {
        out("# 수동 모드가 거절돼서 Ftst=1을 쓰고 다시 시도해요 → \(describe(smc.write("Ftst", 1)))")
        for _ in 0..<8 where !manual {
            usleep(1_000_000)
            manual = setMode(smc, fanList, manual: true)
        }
    }
    guard recorder.sample("B-수동", seconds: 6) else { return 2 }
    guard manual else {
        out("# 수동 모드로 바꾸지 못해 목표 RPM 시험을 건너뛰어요")
        guard recorder.sample("F-확인", seconds: 5) else { return 2 }
        finished = true
        return 3
    }

    for (label, rpm, seconds) in [("C-2500", 2500.0, 20), ("D-3500", 3500.0, 20), ("E-2000", 2000.0, 15)] {
        setTarget(smc, fanList, rpm: rpm)
        guard recorder.sample(label, seconds: seconds) else { return 2 }
    }

    // F: 시스템 제어로 되돌리고 팬이 어떻게 돌아가는지 봐요.
    _ = setMode(smc, fanList, manual: false)
    if smc.number("Ftst") == 1 {
        out("# 쓰기 Ftst=0 → \(describe(smc.write("Ftst", 0)))")
    }
    guard recorder.sample("F-복원", seconds: 25) else { return 2 }
    finished = true
    return 0
}

// MARK: - 시작

guard let smc = SMC() else { exit(1) }
let arguments = CommandLine.arguments
switch arguments.count >= 2 ? arguments[1] : "" {
case "info":
    runInfo(smc)
case "unpriv-write":
    exit(runUnprivilegedWrite(smc))
case "control":
    exit(runControl(smc))
case "restore":
    guard getuid() == 0 else {
        log("restore는 관리자 권한(sudo)으로 실행해야 해요.")
        exit(1)
    }
    exit(restore(smc, reason: "restore 명령") ? 0 : 1)
default:
    log("사용법: fan_probe info | unpriv-write | control | restore")
    exit(1)
}
