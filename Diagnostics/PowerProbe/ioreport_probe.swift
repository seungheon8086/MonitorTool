// IOReport·OS 통계 진단 도구 (PowerProbe 2차)
//
// 관리자 권한 없이 일반 사용자로 실행해서 1초마다 다음을 기록해요.
// 1) IOReport 'Energy Model'의 CPU·GPU·ANE 에너지 카운터가 실제로 갱신되는지.
//    macOS 27에서 CPU·ANE 카운터가 멈추고 powermetrics가 돌 때만 갱신된다는 보고가 있어요.
// 2) 이름에 ANE가 들어간 IOReport 채널. 그중 사용률(활성 비율)로 쓸 만한 값이 있는지.
// 3) E/P 사용률 후보: IOReport 코어·클러스터 활성 비율, OS가 집계한 CPU 시간(host_processor_info).
// 4) GPU 사용률 후보: IOReport GPU 활성 비율, IORegistry의 'Device Utilization %'.
//
// IOReport는 공개 헤더가 없는 비공개 라이브러리라서 함수 형식을 직접 선언해 불러와요.
// 앱에 그대로 넣을 코드가 아니라 확인용이에요.
//
// 빌드와 실행:
//   swiftc -O ioreport_probe.swift -o ioreport_probe
//   ./ioreport_probe list <결과 폴더>                   # 채널 목록 저장
//   ./ioreport_probe sample <초> <결과 폴더> <이름표>    # 1초마다 기록

import Darwin
import Foundation
import IOKit

// MARK: - 공통

/// 진행 상황과 오류는 표준 오류로 바로 써요. 요약 결과만 표준 출력으로 나가요.
func log(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

func fmt(_ value: Double, _ digits: Int = 3) -> String {
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

// MARK: - libIOReport (비공개) 함수

/// dlopen·dlsym으로 불러온 IOReport 함수 모음이에요.
struct IOReport {
    typealias CopyAllChannels = @convention(c) (UInt64, UInt64) -> Unmanaged<CFDictionary>?
    typealias CopyChannelsInGroup = @convention(c) (CFString?, CFString?, UInt64, UInt64, UInt64) -> Unmanaged<CFDictionary>?
    typealias CreateSubscription = @convention(c) (UnsafeRawPointer?, CFMutableDictionary,
                                                   UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>,
                                                   UInt64, UnsafeRawPointer?) -> OpaquePointer?
    typealias CreateSamples = @convention(c) (OpaquePointer, CFMutableDictionary, UnsafeRawPointer?) -> Unmanaged<CFDictionary>?
    typealias CreateSamplesDelta = @convention(c) (CFDictionary, CFDictionary, UnsafeRawPointer?) -> Unmanaged<CFDictionary>?
    typealias ChannelString = @convention(c) (CFDictionary) -> Unmanaged<CFString>?
    typealias ChannelFormat = @convention(c) (CFDictionary) -> UInt8
    typealias SimpleValue = @convention(c) (CFDictionary, Int32) -> Int64
    typealias StateCount = @convention(c) (CFDictionary) -> Int32
    typealias StateName = @convention(c) (CFDictionary, Int32) -> Unmanaged<CFString>?
    typealias StateResidency = @convention(c) (CFDictionary, Int32) -> Int64

    let copyAllChannels: CopyAllChannels?
    let copyChannelsInGroup: CopyChannelsInGroup
    let createSubscription: CreateSubscription
    let createSamples: CreateSamples
    let createSamplesDelta: CreateSamplesDelta
    let groupName: ChannelString
    let subgroupName: ChannelString
    let channelName: ChannelString
    let unitLabel: ChannelString?
    let channelFormat: ChannelFormat?
    let simpleValue: SimpleValue
    let stateCount: StateCount
    let stateName: StateName
    let stateResidency: StateResidency

    init?() {
        guard let handle = dlopen("/usr/lib/libIOReport.dylib", RTLD_NOW) else {
            log("libIOReport를 열지 못했어요: \(dlerror().map { String(cString: $0) } ?? "알 수 없는 오류")")
            return nil
        }

        func load<T>(_ name: String, as type: T.Type) -> T? {
            guard let pointer = dlsym(handle, name) else {
                log("IOReport 함수를 찾지 못했어요: \(name)")
                return nil
            }
            return unsafeBitCast(pointer, to: type)
        }

        guard let copyChannelsInGroup = load("IOReportCopyChannelsInGroup", as: CopyChannelsInGroup.self),
              let createSubscription = load("IOReportCreateSubscription", as: CreateSubscription.self),
              let createSamples = load("IOReportCreateSamples", as: CreateSamples.self),
              let createSamplesDelta = load("IOReportCreateSamplesDelta", as: CreateSamplesDelta.self),
              let groupName = load("IOReportChannelGetGroup", as: ChannelString.self),
              let subgroupName = load("IOReportChannelGetSubGroup", as: ChannelString.self),
              let channelName = load("IOReportChannelGetChannelName", as: ChannelString.self),
              let simpleValue = load("IOReportSimpleGetIntegerValue", as: SimpleValue.self),
              let stateCount = load("IOReportStateGetCount", as: StateCount.self),
              let stateName = load("IOReportStateGetNameForIndex", as: StateName.self),
              let stateResidency = load("IOReportStateGetResidency", as: StateResidency.self) else {
            return nil
        }

        self.copyAllChannels = load("IOReportCopyAllChannels", as: CopyAllChannels.self)
        self.copyChannelsInGroup = copyChannelsInGroup
        self.createSubscription = createSubscription
        self.createSamples = createSamples
        self.createSamplesDelta = createSamplesDelta
        self.groupName = groupName
        self.subgroupName = subgroupName
        self.channelName = channelName
        self.unitLabel = load("IOReportChannelGetUnitLabel", as: ChannelString.self)
        self.channelFormat = load("IOReportChannelGetFormat", as: ChannelFormat.self)
        self.simpleValue = simpleValue
        self.stateCount = stateCount
        self.stateName = stateName
        self.stateResidency = stateResidency
    }

    private func text(_ function: ChannelString?, _ channel: CFDictionary) -> String {
        guard let function, let value = function(channel) else { return "" }
        return value.takeUnretainedValue() as String
    }

    func describe(_ channel: CFDictionary) -> ChannelInfo {
        ChannelInfo(group: text(groupName, channel),
                    subgroup: text(subgroupName, channel),
                    name: text(channelName, channel),
                    unit: text(unitLabel, channel).trimmingCharacters(in: .whitespaces),
                    format: channelFormat?(channel) ?? 0)
    }
}

/// 채널 하나의 이름과 형식이에요.
struct ChannelInfo {
    let group: String
    let subgroup: String
    let name: String
    let unit: String
    /// IOReport 형식 번호 (1: 단순값, 2: 상태, 3: 히스토그램, 4: 단순값 배열)
    let format: UInt8

    var key: String { "\(group) / \(subgroup.isEmpty ? "-" : subgroup) / \(name)" }

    var formatName: String {
        switch format {
        case 1: return "단순값"
        case 2: return "상태"
        case 3: return "히스토그램"
        case 4: return "단순값 배열"
        default: return "알 수 없음(\(format))"
        }
    }

    /// 에너지 단위면 줄(J)로 바꾸는 배율
    var joulesPerUnit: Double? {
        switch unit {
        case "mJ": return 1e-3
        case "uJ", "µJ", "μJ": return 1e-6
        case "nJ": return 1e-9
        default: return nil
        }
    }

    var mentionsANE: Bool {
        containsANE(group) || containsANE(subgroup) || containsANE(name)
    }
}

/// 'ANE'가 단어 앞부분처럼 들어가는지 확인해요. (PLANE 같은 단어는 빼요)
let anePattern = try! NSRegularExpression(pattern: "(?<![A-Za-z])ANE")

func containsANE(_ text: String) -> Bool {
    anePattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
}

/// IOReport 결과 사전에서 채널 목록을 꺼내요.
func channelDictionaries(in dictionary: CFDictionary) -> [CFDictionary] {
    guard let channels = (dictionary as NSDictionary)["IOReportChannels"] as? [NSDictionary] else {
        return []
    }
    return channels.map { $0 as CFDictionary }
}

func allChannels(report: IOReport) -> [ChannelInfo] {
    guard let copyAll = report.copyAllChannels,
          let dictionary = copyAll(0, 0)?.takeRetainedValue() else {
        log("전체 채널 목록을 가져오지 못했어요.")
        return []
    }
    return channelDictionaries(in: dictionary).map { report.describe($0) }
}

/// 그룹(과 하위 그룹) 하나를 구독하고, 부를 때마다 지난번 이후의 변화량을 돌려줘요.
final class Subscription {
    let label: String
    private let report: IOReport
    private let subscription: OpaquePointer
    private let channels: CFMutableDictionary
    private var previous: CFDictionary

    init?(report: IOReport, group: String, subgroup: String?) {
        let label = "\(group) / \(subgroup ?? "(전체)")"
        let subgroupName = subgroup.map { $0 as CFString }
        guard let found = report.copyChannelsInGroup(group as CFString, subgroupName, 0, 0, 0)?.takeRetainedValue(),
              let desired = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, found) else {
            log("채널을 찾지 못했어요: \(label)")
            return nil
        }
        // 구독된 채널 사전의 소유권 규칙이 문서화돼 있지 않아서, 해제하지 않는 쪽(짧은 실행이라 누수 무시)을 택해요.
        var subscribed: Unmanaged<CFMutableDictionary>?
        guard let subscription = report.createSubscription(nil, desired, &subscribed, 0, nil),
              let subscribedChannels = subscribed?.takeUnretainedValue(),
              let first = report.createSamples(subscription, subscribedChannels, nil)?.takeRetainedValue() else {
            log("구독하지 못했어요: \(label)")
            return nil
        }
        self.label = label
        self.report = report
        self.subscription = subscription
        self.channels = subscribedChannels
        self.previous = first
    }

    func delta() -> CFDictionary? {
        guard let current = report.createSamples(subscription, channels, nil)?.takeRetainedValue() else {
            return nil
        }
        defer { previous = current }
        return report.createSamplesDelta(previous, current, nil)?.takeRetainedValue()
    }
}

/// 구독할 그룹이에요.
struct Target: Equatable {
    let group: String
    let subgroup: String?
    /// 상태 채널의 원본 값(상태별 시간)을 TSV에 그대로 남길지
    let keepsRawStates: Bool

    var label: String { "\(group) / \(subgroup ?? "(전체)")" }
}

/// 고정 대상(에너지·CPU·GPU)과, 목록에서 찾은 ANE 관련 그룹·PMP 에너지 그룹을 골라요.
func chooseTargets(from channels: [ChannelInfo]) -> [Target] {
    let fixed = [
        Target(group: "Energy Model", subgroup: nil, keepsRawStates: false),
        Target(group: "CPU Stats", subgroup: "CPU Core Performance States", keepsRawStates: false),
        Target(group: "CPU Stats", subgroup: "CPU Complex Performance States", keepsRawStates: false),
        Target(group: "GPU Stats", subgroup: "GPU Performance States", keepsRawStates: false),
    ]
    var extra: [Target] = []
    for channel in channels where channel.group != "Energy Model" {
        let isPMPEnergy = channel.group == "PMP" && channel.subgroup.localizedCaseInsensitiveContains("energy")
        guard channel.mentionsANE || isPMPEnergy else { continue }
        let target = Target(group: channel.group,
                            subgroup: channel.subgroup.isEmpty ? nil : channel.subgroup,
                            keepsRawStates: true)
        if !extra.contains(target) && !fixed.contains(where: { $0.group == target.group && $0.subgroup == target.subgroup }) {
            extra.append(target)
        }
    }
    if extra.count > 8 {
        log("ANE·PMP 관련 그룹이 \(extra.count)개라 앞의 8개만 구독해요. 나머지: "
            + extra.dropFirst(8).map(\.label).joined(separator: ", "))
        extra = Array(extra.prefix(8))
    }
    return fixed + extra
}

// MARK: - OS 통계

/// host_processor_info의 CPU별 누적 틱이에요.
struct CPUTicks {
    let user: UInt32
    let system: UInt32
    let idle: UInt32
    let nice: UInt32
}

func readCPUTicks() -> [CPUTicks] {
    var cpuCount: natural_t = 0
    var infoPointer: processor_info_array_t?
    var infoCount: mach_msg_type_number_t = 0
    guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &infoPointer, &infoCount) == KERN_SUCCESS,
          let info = infoPointer else {
        return []
    }
    defer {
        vm_deallocate(mach_task_self_,
                      vm_address_t(UInt(bitPattern: info)),
                      vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
    }
    return (0..<Int(cpuCount)).map { cpu in
        let base = cpu * Int(CPU_STATE_MAX)
        return CPUTicks(user: UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]),
                        system: UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]),
                        idle: UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]),
                        nice: UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)]))
    }
}

/// IORegistry의 GPU(IOAccelerator) 'Device Utilization %'를 읽어요.
func readGPUUtilization() -> Int? {
    var iterator: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else {
        return nil
    }
    defer { IOObjectRelease(iterator) }

    var service = IOIteratorNext(iterator)
    while service != 0 {
        let value = deviceUtilization(of: service)
        IOObjectRelease(service)
        if let value { return value }
        service = IOIteratorNext(iterator)
    }
    return nil
}

func deviceUtilization(of service: io_object_t) -> Int? {
    var properties: Unmanaged<CFMutableDictionary>?
    guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
          let dictionary = properties?.takeRetainedValue() as? [String: Any],
          let statistics = dictionary["PerformanceStatistics"] as? [String: Any] else {
        return nil
    }
    return (statistics["Device Utilization %"] as? NSNumber)?.intValue
}

// MARK: - 채널 목록 (list)

func writeChannelList(report: IOReport, directory: String) {
    let channels = allChannels(report: report)

    if let writer = LineWriter(path: "\(directory)/channels.tsv") {
        writer.write(["그룹", "하위 그룹", "채널", "단위", "형식"])
        for channel in channels {
            writer.write([channel.group, channel.subgroup, channel.name, channel.unit, channel.formatName])
        }
    }

    print("== IOReport 채널 목록 ==")
    print("전체 \(channels.count)개, 실행 사용자 uid \(getuid()) (0이 아니면 관리자 권한 없이 실행)")

    print()
    print("[그룹 / 하위 그룹별 채널 수]")
    var counts: [String: Int] = [:]
    for channel in channels {
        counts["\(channel.group) / \(channel.subgroup.isEmpty ? "-" : channel.subgroup)", default: 0] += 1
    }
    for (name, count) in counts.sorted(by: { $0.key < $1.key }) {
        print("\(name): \(count)")
    }

    print()
    print("[이름에 ANE가 들어간 채널]")
    let aneChannels = channels.filter(\.mentionsANE)
    if aneChannels.isEmpty { print("없음") }
    for channel in aneChannels {
        print("\(channel.key) | 단위 \(channel.unit.isEmpty ? "-" : channel.unit) | \(channel.formatName)")
    }

    print()
    print("[Energy Model 채널]")
    for channel in channels where channel.group == "Energy Model" {
        print("\(channel.name) | 단위 \(channel.unit.isEmpty ? "-" : channel.unit) | \(channel.formatName)")
    }

    print()
    print("[sample에서 구독할 대상]")
    for target in chooseTargets(from: channels) {
        print(target.label)
    }
}

// MARK: - 1초마다 기록 (sample)

/// 구간 동안 에너지 채널 하나의 값을 모아요.
struct EnergyStats {
    let info: ChannelInfo
    var samples = 0
    var updated = 0
    var joules = 0.0
    var maxWatts = 0.0
}

/// 구간 동안 상태 채널 하나의 활성 비율을 모아요.
struct StateStats {
    let info: ChannelInfo
    var stateNames: [String] = []
    var samples = 0
    var activeTicks = 0.0
    var totalTicks = 0.0
    var minRatio = Double.infinity
    var maxRatio = -Double.infinity
}

/// 활성 시간에서 뺄 상태 이름
let idleStateNames: Set<String> = ["IDLE", "DOWN", "OFF"]

enum ChannelKind {
    case simple, state, other
}

/// 채널 값을 어떻게 읽을지 정해요.
func kind(of info: ChannelInfo, channel: CFDictionary, report: IOReport) -> ChannelKind {
    switch info.format {
    case 1:
        return .simple
    case 2:
        return .state
    case 0 where report.channelFormat == nil:
        // 형식 함수를 못 불러온 경우: 에너지 단위면 단순값, 상태가 있으면 상태 채널로 봐요.
        if info.joulesPerUnit != nil { return .simple }
        return report.stateCount(channel) > 0 ? .state : .other
    default:
        return .other
    }
}

func runSampling(report: IOReport, seconds: Int, directory: String, label: String) {
    let targets = chooseTargets(from: allChannels(report: report))
    var subscriptions: [(target: Target, subscription: Subscription)] = []
    for target in targets {
        if let subscription = Subscription(report: report, group: target.group, subgroup: target.subgroup) {
            subscriptions.append((target: target, subscription: subscription))
        }
    }

    guard let raw = LineWriter(path: "\(directory)/ioreport-\(label).tsv") else {
        log("결과 파일을 만들 수 없어요: \(directory)/ioreport-\(label).tsv")
        exit(1)
    }
    raw.write(["경과(초)", "그룹", "하위 그룹", "채널", "단위", "형식", "값", "W 또는 활성 비율"])

    var energy: [String: EnergyStats] = [:]
    var states: [String: StateStats] = [:]
    var unparsed: [String: ChannelInfo] = [:]
    var previousTicks = readCPUTicks()
    var cpuBusy = Array(repeating: 0.0, count: previousTicks.count)
    var cpuTotal = Array(repeating: 0.0, count: previousTicks.count)
    var gpuUtilization: [Int] = []

    let clock = ContinuousClock()
    let started = clock.now
    var last = started
    let sampleCount = max(seconds, 1)

    for index in 1...sampleCount {
        let remaining = (started + .seconds(index)) - clock.now
        if remaining > .zero {
            Thread.sleep(forTimeInterval: remaining.inSeconds)
        }
        let now = clock.now
        let interval = (now - last).inSeconds
        last = now
        let elapsed = fmt((now - started).inSeconds, 2)

        for (target, subscription) in subscriptions {
            guard let delta = subscription.delta() else { continue }
            for channel in channelDictionaries(in: delta) {
                let info = report.describe(channel)
                switch kind(of: info, channel: channel, report: report) {
                case .simple:
                    let value = report.simpleValue(channel, 0)
                    guard let scale = info.joulesPerUnit else {
                        raw.write([elapsed, info.group, info.subgroup, info.name, info.unit, "1", String(value), ""])
                        continue
                    }
                    let joules = Double(value) * scale
                    let watts = interval > 0 ? joules / interval : 0
                    var stats = energy[info.key] ?? EnergyStats(info: info)
                    stats.samples += 1
                    if value != 0 { stats.updated += 1 }
                    stats.joules += joules
                    stats.maxWatts = max(stats.maxWatts, watts)
                    energy[info.key] = stats
                    raw.write([elapsed, info.group, info.subgroup, info.name, info.unit, "1", String(value), fmt(watts, 4)])

                case .state:
                    let count = max(report.stateCount(channel), 0)
                    var names: [String] = []
                    var ticks: [Int64] = []
                    for state in 0..<count {
                        names.append(report.stateName(channel, state).map { $0.takeUnretainedValue() as String } ?? "?")
                        ticks.append(report.stateResidency(channel, state))
                    }
                    let total = ticks.reduce(0, +)
                    var idle: Int64 = 0
                    for (name, value) in zip(names, ticks) where idleStateNames.contains(name.uppercased()) {
                        idle += value
                    }
                    let ratio = total > 0 ? Double(total - idle) / Double(total) : 0
                    var stats = states[info.key] ?? StateStats(info: info)
                    if stats.stateNames.isEmpty { stats.stateNames = names }
                    stats.samples += 1
                    stats.activeTicks += Double(total - idle)
                    stats.totalTicks += Double(total)
                    if total > 0 {
                        stats.minRatio = min(stats.minRatio, ratio)
                        stats.maxRatio = max(stats.maxRatio, ratio)
                    }
                    states[info.key] = stats
                    let rawStates = target.keepsRawStates
                        ? zip(names, ticks).map { "\($0.0)=\($0.1)" }.joined(separator: ";")
                        : ""
                    raw.write([elapsed, info.group, info.subgroup, info.name, info.unit, "2", rawStates, fmt(ratio, 4)])

                case .other:
                    if unparsed[info.key] == nil {
                        unparsed[info.key] = info
                    }
                }
            }
        }

        let ticks = readCPUTicks()
        if ticks.count == previousTicks.count {
            for (cpu, pair) in zip(ticks, previousTicks).enumerated() {
                let (current, old) = pair
                let busy = Double(current.user &- old.user) + Double(current.system &- old.system)
                    + Double(current.nice &- old.nice)
                let idle = Double(current.idle &- old.idle)
                cpuBusy[cpu] += busy
                cpuTotal[cpu] += busy + idle
                let ratio = busy + idle > 0 ? busy / (busy + idle) : 0
                raw.write([elapsed, "OS", "host_processor_info", "CPU \(cpu)", "", "", "", fmt(ratio, 4)])
            }
        }
        previousTicks = ticks

        if let utilization = readGPUUtilization() {
            gpuUtilization.append(utilization)
            raw.write([elapsed, "IORegistry", "PerformanceStatistics", "Device Utilization %", "%", "", String(utilization), ""])
        }

        if index % 5 == 0 {
            log("\(index)/\(sampleCount)초")
        }
    }

    // MARK: 요약

    let measured = (last - started).inSeconds
    print("== IOReport 진단: \(label) ==")
    print("측정 \(fmt(measured, 1))초, 1초 간격, 실행 사용자 uid \(getuid()) (0이 아니면 관리자 권한 없이 실행)")
    print("구독: " + subscriptions.map { $0.subscription.label }.joined(separator: ", "))
    let failed = targets.filter { target in !subscriptions.contains { $0.target == target } }
    if !failed.isEmpty {
        print("구독 실패: " + failed.map(\.label).joined(separator: ", "))
    }

    print()
    print("[에너지 카운터] 평균 W = 구간 총 에너지 ÷ 측정 시간, '갱신'은 값이 0이 아니었던 표본 수")
    if energy.isEmpty { print("없음") }
    for stats in energy.values.sorted(by: { $0.info.key < $1.info.key }) {
        let average = measured > 0 ? stats.joules / measured : 0
        print("\(stats.info.key) | \(stats.info.unit) | 갱신 \(stats.updated)/\(stats.samples) | 평균 \(fmt(average)) W | 최대 \(fmt(stats.maxWatts)) W")
    }

    print()
    print("[상태 채널] 활성 % = IDLE·DOWN·OFF를 뺀 시간 비율 (구간 전체 기준, 괄호는 표본별 최소~최대)")
    if states.isEmpty { print("없음") }
    for stats in states.values.sorted(by: { $0.info.key < $1.info.key }) {
        let ratio = stats.totalTicks > 0 ? stats.activeTicks / stats.totalTicks * 100 : 0
        let range = stats.maxRatio >= stats.minRatio
            ? "\(fmt(stats.minRatio * 100, 1))~\(fmt(stats.maxRatio * 100, 1))"
            : "-"
        let shown = stats.stateNames.prefix(16).joined(separator: ",")
        let more = stats.stateNames.count > 16 ? ",…" : ""
        print("\(stats.info.key) | 활성 \(fmt(ratio, 1))% (\(range)) | 상태 \(stats.stateNames.count)개: \(shown)\(more)")
    }

    if !unparsed.isEmpty {
        print()
        print("[값을 해석하지 않은 채널] (단순값·상태가 아닌 형식)")
        for info in unparsed.values.sorted(by: { $0.key < $1.key }) {
            print("\(info.key) | \(info.formatName)")
        }
    }

    print()
    print("[OS CPU 시간] host_processor_info의 (user+system+nice) ÷ 전체 (구간 전체 기준)")
    if cpuBusy.isEmpty { print("읽지 못함") }
    for cpu in cpuBusy.indices {
        let ratio = cpuTotal[cpu] > 0 ? cpuBusy[cpu] / cpuTotal[cpu] * 100 : 0
        print("CPU \(cpu): \(fmt(ratio, 1))%")
    }

    print()
    if let low = gpuUtilization.min(), let high = gpuUtilization.max() {
        let average = Double(gpuUtilization.reduce(0, +)) / Double(gpuUtilization.count)
        print("[IORegistry GPU] Device Utilization %: 평균 \(fmt(average, 1)) (최소 \(low)~최대 \(high), \(gpuUtilization.count)회)")
    } else {
        print("[IORegistry GPU] Device Utilization %: 읽지 못함")
    }
}

// MARK: - 시작

let arguments = CommandLine.arguments
let usage = "사용법: ioreport_probe list <결과 폴더> | ioreport_probe sample <초> <결과 폴더> <이름표>"

guard let report = IOReport() else {
    log("IOReport를 불러오지 못했어요.")
    exit(1)
}

switch arguments.count > 1 ? arguments[1] : "" {
case "list" where arguments.count >= 3:
    writeChannelList(report: report, directory: arguments[2])
case "sample" where arguments.count >= 5:
    guard let seconds = Int(arguments[2]) else {
        log(usage)
        exit(1)
    }
    runSampling(report: report, seconds: seconds, directory: arguments[3], label: arguments[4])
default:
    log(usage)
    exit(1)
}
