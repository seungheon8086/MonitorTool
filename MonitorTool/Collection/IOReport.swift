import Darwin
import Foundation

/// 비공개 라이브러리 libIOReport의 함수 모음이에요. 공개 헤더가 없어서 함수 형식을 직접 적고 dlsym으로 불러와요.
/// 관리자 권한 없이 GPU 에너지, ANE 전원 상태, 메모리 컨트롤러의 바이트 카운터를 읽을 때 써요.
/// (함수 형식과 쓰는 법은 Diagnostics/PowerProbe의 ioreport_probe.swift로 이 Mac에서 확인했어요)
nonisolated struct IOReportLibrary {
    typealias CopyChannelsInGroup = @convention(c) (CFString?, CFString?, UInt64, UInt64, UInt64) -> Unmanaged<CFDictionary>?
    typealias CreateSubscription = @convention(c) (UnsafeRawPointer?, CFMutableDictionary,
                                                   UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>,
                                                   UInt64, UnsafeRawPointer?) -> OpaquePointer?
    typealias CreateSamples = @convention(c) (OpaquePointer, CFMutableDictionary, UnsafeRawPointer?) -> Unmanaged<CFDictionary>?
    typealias CreateSamplesDelta = @convention(c) (CFDictionary, CFDictionary, UnsafeRawPointer?) -> Unmanaged<CFDictionary>?
    typealias ChannelString = @convention(c) (CFDictionary) -> Unmanaged<CFString>?
    typealias SimpleValue = @convention(c) (CFDictionary, Int32) -> Int64
    typealias StateCount = @convention(c) (CFDictionary) -> Int32
    typealias StateName = @convention(c) (CFDictionary, Int32) -> Unmanaged<CFString>?
    typealias StateResidency = @convention(c) (CFDictionary, Int32) -> Int64

    let copyChannelsInGroup: CopyChannelsInGroup
    let createSubscription: CreateSubscription
    let createSamples: CreateSamples
    let createSamplesDelta: CreateSamplesDelta
    let channelName: ChannelString
    /// 단위 이름 (없는 macOS도 있을 수 있어서 선택)
    let unitLabel: ChannelString?
    let simpleValue: SimpleValue
    let stateCount: StateCount
    let stateName: StateName
    let stateResidency: StateResidency

    /// 상태 채널에서 쉬는 상태로 보는 이름이에요. (SoC Stats의 전원 상태는 INACT·ACT 두 가지예요)
    static let idleStateNames: Set<String> = ["INACT", "IDLE", "OFF", "DOWN"]

    /// 라이브러리나 꼭 필요한 함수를 찾지 못하면 nil이에요.
    init?() {
        guard let handle = dlopen("/usr/lib/libIOReport.dylib", RTLD_NOW) else {
            return nil
        }
        func load<Function>(_ name: String, as type: Function.Type) -> Function? {
            guard let pointer = dlsym(handle, name) else {
                return nil
            }
            return unsafeBitCast(pointer, to: type)
        }
        guard let copyChannelsInGroup = load("IOReportCopyChannelsInGroup", as: CopyChannelsInGroup.self),
              let createSubscription = load("IOReportCreateSubscription", as: CreateSubscription.self),
              let createSamples = load("IOReportCreateSamples", as: CreateSamples.self),
              let createSamplesDelta = load("IOReportCreateSamplesDelta", as: CreateSamplesDelta.self),
              let channelName = load("IOReportChannelGetChannelName", as: ChannelString.self),
              let simpleValue = load("IOReportSimpleGetIntegerValue", as: SimpleValue.self),
              let stateCount = load("IOReportStateGetCount", as: StateCount.self),
              let stateName = load("IOReportStateGetNameForIndex", as: StateName.self),
              let stateResidency = load("IOReportStateGetResidency", as: StateResidency.self) else {
            return nil
        }
        self.copyChannelsInGroup = copyChannelsInGroup
        self.createSubscription = createSubscription
        self.createSamples = createSamples
        self.createSamplesDelta = createSamplesDelta
        self.channelName = channelName
        self.unitLabel = load("IOReportChannelGetUnitLabel", as: ChannelString.self)
        self.simpleValue = simpleValue
        self.stateCount = stateCount
        self.stateName = stateName
        self.stateResidency = stateResidency
    }
}

extension IOReportLibrary {
    /// 표본(또는 델타) 안의 채널 목록
    nonisolated static func channels(in samples: CFDictionary) -> [CFDictionary] {
        guard let list = (samples as NSDictionary)["IOReportChannels"] as? [NSDictionary] else {
            return []
        }
        return list.map { $0 as CFDictionary }
    }

    /// 채널 이름 (예: 'GPU Energy', 'ANE0', 'GFX DCS RD')
    nonisolated func name(of channel: CFDictionary) -> String {
        guard let name = channelName(channel) else {
            return ""
        }
        return name.takeUnretainedValue() as String
    }

    /// 단위 이름 (예: 'nJ', 'B'). 모르면 빈 글자예요.
    nonisolated func unit(of channel: CFDictionary) -> String {
        guard let unitLabel, let unit = unitLabel(channel) else {
            return ""
        }
        return (unit.takeUnretainedValue() as String).trimmingCharacters(in: .whitespaces)
    }

    /// 상태 채널에서 쉬는 상태를 뺀 시간 (단위는 채널마다 달라서 비율로만 써요)
    nonisolated func activeResidency(of channel: CFDictionary) -> Int64 {
        var active: Int64 = 0
        for index in 0..<max(stateCount(channel), 0) {
            let name = stateName(channel, index).map { $0.takeUnretainedValue() as String } ?? ""
            if !IOReportLibrary.idleStateNames.contains(name.uppercased()) {
                active += max(stateResidency(channel, index), 0)
            }
        }
        return active
    }

    /// 에너지 단위를 줄(J)로 바꾸는 배율. 에너지 단위가 아니면 nil이에요.
    nonisolated static func joulesPerUnit(_ unit: String) -> Double? {
        switch unit {
        case "J":
            return 1
        case "mJ":
            return 1e-3
        case "uJ", "µJ", "μJ":
            return 1e-6
        case "nJ":
            return 1e-9
        default:
            return nil
        }
    }
}

/// IOReport 그룹 하나(하위 그룹을 정하면 그것만)를 구독해요.
/// 부를 때마다 지난번에 부른 뒤(처음에는 구독한 뒤) 늘어난 양을 채널별로 돌려줘요.
final class IOReportSubscription {
    private let library: IOReportLibrary
    private let subscription: OpaquePointer
    private let channels: CFMutableDictionary
    private var previous: CFDictionary

    /// 그룹을 찾지 못하거나 구독하지 못하면 nil이에요.
    /// - Parameter keep: 이름으로 고른 채널만 구독해요. 표본을 만들고 훑는 채널이 줄어서 가벼워져요.
    ///   고른 채널이 없거나 고른 채널로 구독하지 못하면 그룹 전체를 구독해요.
    convenience init?(library: IOReportLibrary, group: String, subgroup: String? = nil,
                      keep: ((String) -> Bool)? = nil) {
        let subgroupName = subgroup.map { $0 as CFString }
        guard let found = library.copyChannelsInGroup(group as CFString, subgroupName, 0, 0, 0)?.takeRetainedValue() else {
            return nil
        }
        if let keep {
            let kept = IOReportLibrary.channels(in: found).filter { keep(library.name(of: $0)) }
            if !kept.isEmpty,
               let desired = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, found) {
                (desired as NSMutableDictionary)["IOReportChannels"] = kept as NSArray
                if let parts = IOReportSubscription.subscribe(library: library, desired: desired) {
                    self.init(library: library, parts: parts)
                    return
                }
            }
        }
        guard let desired = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, found),
              let parts = IOReportSubscription.subscribe(library: library, desired: desired) else {
            return nil
        }
        self.init(library: library, parts: parts)
    }

    private init(library: IOReportLibrary, parts: (subscription: OpaquePointer, channels: CFMutableDictionary, first: CFDictionary)) {
        self.library = library
        self.subscription = parts.subscription
        self.channels = parts.channels
        self.previous = parts.first
    }

    /// 구독하고 첫 표본을 만들어요. 실패하면 nil이에요.
    private static func subscribe(library: IOReportLibrary, desired: CFMutableDictionary)
        -> (subscription: OpaquePointer, channels: CFMutableDictionary, first: CFDictionary)? {
        // 구독한 채널 사전의 소유 규칙은 문서가 없어서 놓지 않아요. 앱이 켜져 있는 동안 한 번만 만들어요.
        var subscribed: Unmanaged<CFMutableDictionary>?
        guard let subscription = library.createSubscription(nil, desired, &subscribed, 0, nil),
              let subscribedChannels = subscribed?.takeUnretainedValue(),
              let first = library.createSamples(subscription, subscribedChannels, nil)?.takeRetainedValue() else {
            return nil
        }
        return (subscription, subscribedChannels, first)
    }

    /// 지난번 표본 뒤로 늘어난 양 (채널 목록). 표본을 만들지 못하면 nil이에요.
    func delta() -> [CFDictionary]? {
        guard let current = library.createSamples(subscription, channels, nil)?.takeRetainedValue() else {
            return nil
        }
        defer { previous = current }
        guard let delta = library.createSamplesDelta(previous, current, nil)?.takeRetainedValue() else {
            return nil
        }
        return IOReportLibrary.channels(in: delta)
    }
}
