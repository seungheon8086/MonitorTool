// 온도·팬·전력 센서 읽기 진단 도구 (SensorProbe)
//
// 관리자 권한 없이 일반 사용자로 실행해서 다음을 확인해요. 값을 바꾸는 명령은 보내지 않아요(읽기 전용).
// 1) SMC 키 목록과 값: 온도(T…)·팬(F…)·전력(P…) 키가 무엇이 있고 어떤 형식인지
// 2) HID 온도 센서 목록과 값 (IOHIDEventSystemClient, 비공개 API)
// 3) 부하를 바꿔 가며 1초마다 기록해서, 어느 센서가 어느 부하에 반응하는지
// 4) ANE 드라이버(IORegistry) 속성 중 사용률로 쓸 만한 값이 있는지
//
// SMC는 읽기(5), 키 정보(9), 번호로 키 찾기(8) 명령만 써요. 쓰기(6) 명령은 쓰지 않아요.
// 앱에 그대로 넣을 코드가 아니라 확인용이에요.
//
// 빌드와 실행:
//   swiftc -O sensor_probe.swift -o sensor_probe
//   ./sensor_probe list <결과 폴더>                   # SMC 키 전체·HID 센서 목록 저장
//   ./sensor_probe sample <초> <결과 폴더> <이름표>    # T·F·P 키와 HID 온도를 1초마다 기록
//   ./sensor_probe ane-ioreg <결과 폴더> <이름표>      # ANE 관련 IORegistry 속성 저장

import Darwin
import Foundation
import IOKit

// MARK: - 공통

/// 진행 상황과 오류는 표준 오류로 바로 써요. 요약 결과만 표준 출력으로 나가요.
func log(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

func fmt(_ value: Double, _ digits: Int = 2) -> String {
    String(format: "%.\(digits)f", value)
}

extension Duration {
    var inSeconds: Double {
        let parts = components
        return Double(parts.seconds) + Double(parts.attoseconds) * 1e-18
    }
}

/// 결과 파일(TSV)에 한 줄씩 써요.
final class LineWriter {
    private let handle: FileHandle

    init?(path: String) {
        guard FileManager.default.createFile(atPath: path, contents: nil),
              let handle = FileHandle(forWritingAtPath: path) else {
            return nil
        }
        self.handle = handle
    }

    func write(_ fields: [String]) {
        handle.write(Data((fields.joined(separator: "\t") + "\n").utf8))
    }

    deinit {
        try? handle.close()
    }
}

/// 'ANE'가 단어 앞부분처럼 들어가는지 확인해요. (PLANE 같은 단어는 빼요)
let anePattern = try! NSRegularExpression(pattern: "(?<![A-Za-z])ANE")

func containsANE(_ text: String) -> Bool {
    anePattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
}

// MARK: - SMC (읽기 전용)

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

/// AppleSMC와 주고받는 구조체예요. C 구조체와 같은 80바이트 배치가 되도록 keyInfo 뒤를 채웠어요.
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
    /// IOKit 호출 자체가 실패
    case call(kern_return_t)
    /// SMC가 오류 코드를 돌려줌 (132 = 키 없음)
    case smc(UInt8)

    var text: String {
        switch self {
        case .call(let code): return "IOKit 오류 \(code)"
        case .smc(let code): return "SMC 오류 \(code)"
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

/// 숫자로 해석할 수 있는 SMC 형식
let numericTypes: Set<String> = ["flt ", "ui8 ", "ui16", "ui32", "si8 ", "si16", "sp78", "fpe2", "flag"]

/// SMC 값을 형식에 맞춰 숫자로 바꿔요. Apple Silicon의 flt는 리틀 엔디언, 정수·고정소수점 형식은 빅 엔디언이에요.
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

/// SMC 키 하나를 읽은 결과예요.
struct SMCValue {
    let type: String
    let size: Int
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

    func read(_ key: String, info: SMCKeyInfo) -> Result<SMCValue, SMCError> {
        var request = SMCKeyData()
        request.key = fourCC(key)
        request.keyInfo.dataSize = info.dataSize
        request.data8 = 5   // kSMCReadKey
        return call(request).map { output in
            let size = Int(min(info.dataSize, 32))
            let bytes = withUnsafeBytes(of: output.bytes) { Array($0.prefix(size)) }
            return SMCValue(type: fourCCString(info.dataType), size: Int(info.dataSize), bytes: bytes)
        }
    }

    func read(_ key: String) -> Result<SMCValue, SMCError> {
        switch keyInfo(key) {
        case .success(let info): return read(key, info: info)
        case .failure(let error): return .failure(error)
        }
    }

    func key(at index: UInt32) -> String? {
        var request = SMCKeyData()
        request.data8 = 8   // kSMCGetKeyFromIndex
        request.data32 = index
        guard case .success(let output) = call(request) else { return nil }
        return fourCCString(output.key)
    }

    func keyCount() -> Int? {
        guard case .success(let value) = read("#KEY"), let count = value.number else { return nil }
        return Int(count)
    }

    /// 전체 키 이름 목록
    func allKeys() -> [String] {
        guard let count = keyCount() else {
            log("SMC 키 개수(#KEY)를 읽지 못했어요.")
            return []
        }
        return (0..<count).compactMap { key(at: UInt32($0)) }
    }
}

// MARK: - HID 온도 센서 (비공개 API)

final class HIDSensors {
    typealias ClientCreate = @convention(c) (CFAllocator?) -> OpaquePointer?
    typealias ClientSetMatching = @convention(c) (OpaquePointer, CFDictionary) -> Int32
    typealias ClientCopyServices = @convention(c) (OpaquePointer) -> Unmanaged<CFArray>?
    typealias ServiceCopyProperty = @convention(c) (OpaquePointer, CFString) -> Unmanaged<CFTypeRef>?
    typealias ServiceCopyEvent = @convention(c) (OpaquePointer, Int64, Int32, Int64) -> OpaquePointer?
    typealias EventGetFloatValue = @convention(c) (OpaquePointer, Int32) -> Double

    private let copyEvent: ServiceCopyEvent
    private let floatValue: EventGetFloatValue
    /// 서비스 참조가 계속 유효하도록 배열을 붙잡아 둬요.
    private let services: CFArray
    let sensors: [(name: String, service: OpaquePointer)]

    init?() {
        guard let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW) else {
            log("IOKit을 열지 못했어요.")
            return nil
        }

        func load<T>(_ name: String, as type: T.Type) -> T? {
            guard let pointer = dlsym(handle, name) else {
                log("HID 함수를 찾지 못했어요: \(name)")
                return nil
            }
            return unsafeBitCast(pointer, to: type)
        }

        guard let create = load("IOHIDEventSystemClientCreate", as: ClientCreate.self),
              let setMatching = load("IOHIDEventSystemClientSetMatching", as: ClientSetMatching.self),
              let copyServices = load("IOHIDEventSystemClientCopyServices", as: ClientCopyServices.self),
              let copyProperty = load("IOHIDServiceClientCopyProperty", as: ServiceCopyProperty.self),
              let copyEvent = load("IOHIDServiceClientCopyEvent", as: ServiceCopyEvent.self),
              let floatValue = load("IOHIDEventGetFloatValue", as: EventGetFloatValue.self),
              let client = create(kCFAllocatorDefault) else {
            return nil
        }

        // 온도 센서만: PrimaryUsagePage 0xff00, PrimaryUsage 5
        let matching = ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary
        _ = setMatching(client, matching)
        guard let services = copyServices(client)?.takeRetainedValue() else {
            log("HID 온도 센서 목록을 가져오지 못했어요.")
            return nil
        }

        var found: [(name: String, service: OpaquePointer)] = []
        for index in 0..<CFArrayGetCount(services) {
            guard let raw = CFArrayGetValueAtIndex(services, index) else { continue }
            let service = OpaquePointer(raw)
            let name = (copyProperty(service, "Product" as CFString)?.takeRetainedValue() as? String) ?? "(이름 없음)"
            found.append((name: name, service: service))
        }

        self.copyEvent = copyEvent
        self.floatValue = floatValue
        self.services = services
        self.sensors = found
    }

    /// 온도(°C). 읽지 못하면 nil
    func temperature(of service: OpaquePointer) -> Double? {
        // 15 = kIOHIDEventTypeTemperature, 15 << 16 = kIOHIDEventFieldTemperatureLevel
        guard let event = copyEvent(service, 15, 0, 0) else { return nil }
        defer { Unmanaged<AnyObject>.fromOpaque(UnsafeRawPointer(event)).release() }
        return floatValue(event, 15 << 16)
    }
}

// MARK: - 목록 (list)

func writeList(smc: SMC?, hid: HIDSensors?, directory: String) {
    print("== SMC·HID 센서 목록 ==")
    print("실행 사용자 uid \(getuid()) (0이 아니면 관리자 권한 없이 실행)")

    if let smc {
        let keys = smc.allKeys()
        var byFirst: [Character: Int] = [:]
        var rows: [(key: String, type: String, value: String)] = []
        if let writer = LineWriter(path: "\(directory)/smc-keys.tsv") {
            writer.write(["번호", "키", "형식", "크기", "숫자 값", "원본(hex)", "결과"])
            for (index, key) in keys.enumerated() {
                if let first = key.first { byFirst[first, default: 0] += 1 }
                switch smc.read(key) {
                case .success(let value):
                    let number = value.number.map { fmt($0, 3) } ?? ""
                    writer.write([String(index), key, value.type, String(value.size), number, value.hex, "성공"])
                    rows.append((key: key, type: value.type, value: number.isEmpty ? "hex \(value.hex)" : number))
                case .failure(let error):
                    writer.write([String(index), key, "", "", "", "", error.text])
                    rows.append((key: key, type: "?", value: error.text))
                }
            }
        }
        print("SMC 키 \(keys.count)개 (전체 목록은 smc-keys.tsv)")
        print("첫 글자별 개수: " + byFirst.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
        for (title, prefix) in [("온도 후보 (T…)", "T"), ("팬 (F…)", "F"), ("전력 후보 (P…)", "P")] {
            print()
            print("[\(title)]")
            for row in rows where row.key.hasPrefix(prefix) {
                print("\(row.key) | \(row.type) | \(row.value)")
            }
        }
    } else {
        print("SMC를 열지 못했어요.")
    }

    print()
    print("[HID 온도 센서]")
    if let hid {
        for sensor in hid.sensors {
            let value = hid.temperature(of: sensor.service).map { fmt($0) + " °C" } ?? "읽지 못함"
            print("\(sensor.name) | \(value)")
        }
        print("총 \(hid.sensors.count)개")
    } else {
        print("HID 센서를 불러오지 못했어요.")
    }
}

// MARK: - 1초마다 기록 (sample)

/// 구간 동안 센서 하나의 값을 모아요.
struct SensorStats {
    var count = 0
    var failures = 0
    var sum = 0.0
    var low = Double.infinity
    var high = -Double.infinity
    var first: Double?
    var last: Double?

    mutating func add(_ value: Double) {
        count += 1
        sum += value
        low = min(low, value)
        high = max(high, value)
        if first == nil { first = value }
        last = value
    }
}

func runSampling(smc: SMC?, hid: HIDSensors?, seconds: Int, directory: String, label: String) {
    // 기록할 SMC 키: T(온도)·F(팬)·P(전력)로 시작하고 숫자로 읽히는 키
    var keys: [(key: String, info: SMCKeyInfo)] = []
    if let smc {
        for key in smc.allKeys() {
            guard let first = key.first, "TFP".contains(first),
                  case .success(let info) = smc.keyInfo(key),
                  numericTypes.contains(fourCCString(info.dataType)) else { continue }
            keys.append((key: key, info: info))
        }
    }

    guard let raw = LineWriter(path: "\(directory)/sample-\(label).tsv") else {
        log("결과 파일을 만들 수 없어요: \(directory)/sample-\(label).tsv")
        exit(1)
    }
    raw.write(["시각(epoch)", "경과(초)", "출처", "이름", "값", "비고"])

    var stats: [String: SensorStats] = [:]
    let clock = ContinuousClock()
    let started = clock.now
    var last = started
    let sampleCount = max(seconds, 1)

    for index in 1...sampleCount {
        let remaining = (started + .seconds(index)) - clock.now
        if remaining > .zero {
            Thread.sleep(forTimeInterval: remaining.inSeconds)
        }
        last = clock.now
        let epoch = fmt(Date().timeIntervalSince1970, 3)
        let elapsed = fmt((last - started).inSeconds, 2)

        if let smc {
            for entry in keys {
                let name = "SMC \(entry.key)"
                switch smc.read(entry.key, info: entry.info) {
                case .success(let value):
                    if let number = value.number {
                        stats[name, default: SensorStats()].add(number)
                        raw.write([epoch, elapsed, "SMC", entry.key, fmt(number, 3), ""])
                    } else {
                        stats[name, default: SensorStats()].failures += 1
                        raw.write([epoch, elapsed, "SMC", entry.key, "", "해석 불가 \(value.hex)"])
                    }
                case .failure(let error):
                    stats[name, default: SensorStats()].failures += 1
                    raw.write([epoch, elapsed, "SMC", entry.key, "", error.text])
                }
            }
        }

        if let hid {
            for sensor in hid.sensors {
                let name = "HID \(sensor.name)"
                if let value = hid.temperature(of: sensor.service) {
                    stats[name, default: SensorStats()].add(value)
                    raw.write([epoch, elapsed, "HID", sensor.name, fmt(value, 3), ""])
                } else {
                    stats[name, default: SensorStats()].failures += 1
                    raw.write([epoch, elapsed, "HID", sensor.name, "", "읽지 못함"])
                }
            }
        }

        if index % 5 == 0 {
            log("\(index)/\(sampleCount)초")
        }
    }

    print("== 센서 기록: \(label) ==")
    print("측정 \(fmt((last - started).inSeconds, 1))초, 1초 간격, 실행 사용자 uid \(getuid()), SMC 키 \(keys.count)개, HID 센서 \(hid?.sensors.count ?? 0)개")
    print("이름 | 평균 | 최소 | 최대 | 처음 → 마지막 | 실패 횟수")
    for (name, item) in stats.sorted(by: { $0.key < $1.key }) {
        guard item.count > 0 else {
            print("\(name) | 값 없음 | | | | \(item.failures)")
            continue
        }
        let average = item.sum / Double(item.count)
        let change = "\(fmt(item.first ?? 0)) → \(fmt(item.last ?? 0))"
        print("\(name) | \(fmt(average)) | \(fmt(item.low)) | \(fmt(item.high)) | \(change) | \(item.failures)")
    }
}

// MARK: - ANE 드라이버 속성 (ane-ioreg)

/// IOKit의 이름 버퍼(128바이트)를 채우는 함수를 불러 문자열로 바꿔요.
func ioName(_ body: (UnsafeMutablePointer<CChar>) -> kern_return_t) -> String {
    var buffer = [CChar](repeating: 0, count: 128)
    _ = buffer.withUnsafeMutableBufferPointer { pointer in
        body(pointer.baseAddress!)
    }
    return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
}

/// 속성 값을 "경로 = 값" 줄들로 펼쳐요.
func flatten(_ value: Any, prefix: String, depth: Int = 0) -> [String] {
    switch value {
    case let dictionary as [String: Any]:
        guard depth < 4 else { return ["\(prefix) = {…}"] }
        return dictionary.sorted { $0.key < $1.key }.flatMap { item in
            flatten(item.value, prefix: prefix.isEmpty ? item.key : "\(prefix).\(item.key)", depth: depth + 1)
        }
    case let array as [Any]:
        guard depth < 4 else { return ["\(prefix) = […]"] }
        return array.enumerated().flatMap { item in
            flatten(item.element, prefix: "\(prefix)[\(item.offset)]", depth: depth + 1)
        }
    case let data as Data:
        let hex = data.prefix(16).map { String(format: "%02x", $0) }.joined()
        return ["\(prefix) = <\(data.count) bytes \(hex)\(data.count > 16 ? "…" : "")>"]
    default:
        return ["\(prefix) = \(value)"]
    }
}

func dumpANERegistry(directory: String, label: String) {
    var iterator: io_iterator_t = 0
    guard IORegistryCreateIterator(kIOMainPortDefault, kIOServicePlane,
                                   IOOptionBits(kIORegistryIterateRecursively), &iterator) == KERN_SUCCESS else {
        print("IORegistry를 훑지 못했어요.")
        return
    }
    defer { IOObjectRelease(iterator) }
    guard let writer = LineWriter(path: "\(directory)/ane-ioreg-\(label).txt") else {
        print("결과 파일을 만들 수 없어요.")
        return
    }

    var matched = 0
    var entry = IOIteratorNext(iterator)
    while entry != 0 {
        let className = ioName { IOObjectGetClass(entry, $0) }
        let name = ioName { IORegistryEntryGetName(entry, $0) }
        if containsANE(className) || containsANE(name) {
            matched += 1
            writer.write(["== \(name) (\(className))"])
            var properties: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(entry, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
               let dictionary = properties?.takeRetainedValue() as? [String: Any] {
                for line in flatten(dictionary, prefix: "") {
                    writer.write([line])
                }
            }
        }
        IOObjectRelease(entry)
        entry = IOIteratorNext(iterator)
    }
    print("ANE 관련 IORegistry 항목 \(matched)개 → ane-ioreg-\(label).txt")
}

// MARK: - 시작

let arguments = CommandLine.arguments
let usage = "사용법: sensor_probe list <결과 폴더> | sensor_probe sample <초> <결과 폴더> <이름표> | sensor_probe ane-ioreg <결과 폴더> <이름표>"

guard MemoryLayout<SMCKeyData>.size == 80 else {
    log("SMC 구조체 크기가 80바이트가 아니에요(\(MemoryLayout<SMCKeyData>.size)). 배치를 고쳐야 해요.")
    exit(1)
}

switch arguments.count > 1 ? arguments[1] : "" {
case "list" where arguments.count >= 3:
    writeList(smc: SMC(), hid: HIDSensors(), directory: arguments[2])
case "sample" where arguments.count >= 5:
    guard let seconds = Int(arguments[2]) else {
        log(usage)
        exit(1)
    }
    runSampling(smc: SMC(), hid: HIDSensors(), seconds: seconds, directory: arguments[3], label: arguments[4])
case "ane-ioreg" where arguments.count >= 4:
    dumpANERegistry(directory: arguments[2], label: arguments[3])
default:
    log(usage)
    exit(1)
}
