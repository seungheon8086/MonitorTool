// 2단계 비교용: IOReport(비공개 libIOReport)로 저장장치 채널(ANS2·NVMe·SDXC)을 권한 없이 읽는다.
// 함수 형식은 앱의 MonitorTool/Collection/IOReport.swift, Diagnostics/PowerProbe와 같다.
import Darwin
import Foundation

struct IOReportLibrary {
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

    let copyChannelsInGroup: CopyChannelsInGroup
    let createSubscription: CreateSubscription
    let createSamples: CreateSamples
    let createSamplesDelta: CreateSamplesDelta
    let groupName: ChannelString
    let subgroupName: ChannelString
    let channelName: ChannelString
    /// 형식 번호 (1 단순값, 2 상태, 3 히스토그램, 4 단순값 배열). 없는 macOS도 있을 수 있어서 선택
    let channelFormat: ChannelFormat?
    let simpleValue: SimpleValue
    let stateCount: StateCount
    let stateName: StateName
    let stateResidency: StateResidency

    /// 라이브러리나 꼭 필요한 함수를 찾지 못하면 nil
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
              let groupName = load("IOReportChannelGetGroup", as: ChannelString.self),
              let subgroupName = load("IOReportChannelGetSubGroup", as: ChannelString.self),
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
        self.groupName = groupName
        self.subgroupName = subgroupName
        self.channelName = channelName
        self.channelFormat = load("IOReportChannelGetFormat", as: ChannelFormat.self)
        self.simpleValue = simpleValue
        self.stateCount = stateCount
        self.stateName = stateName
        self.stateResidency = stateResidency
    }

    /// 표본(또는 델타) 안의 채널 목록
    static func channels(in samples: CFDictionary) -> [CFDictionary] {
        guard let list = (samples as NSDictionary)["IOReportChannels"] as? [NSDictionary] else {
            return []
        }
        return list.map { $0 as CFDictionary }
    }

    func text(_ function: ChannelString, _ channel: CFDictionary) -> String {
        guard let value = function(channel) else {
            return ""
        }
        return value.takeUnretainedValue() as String
    }

    /// '그룹 / 하위 그룹 / 채널'
    func key(of channel: CFDictionary) -> String {
        let subgroup = text(subgroupName, channel)
        return "\(text(groupName, channel)) / \(subgroup.isEmpty ? "-" : subgroup) / \(text(channelName, channel))"
    }

    /// 상태 채널인지 (형식 함수가 없으면 상태가 있는지로 본다)
    func isState(_ channel: CFDictionary) -> Bool {
        let format = channelFormat?(channel) ?? 0
        return format == 2 || (format == 0 && stateCount(channel) > 0)
    }

    func isSimple(_ channel: CFDictionary) -> Bool {
        (channelFormat?(channel) ?? 0) == 1
    }

    /// 채널 하나를 값 목록으로: 상태 채널은 상태마다 하나, 단순값은 하나
    func values(of channel: CFDictionary) -> [(state: String, value: Int64)] {
        if isState(channel) {
            var out: [(state: String, value: Int64)] = []
            let count = max(stateCount(channel), 0)
            for index in 0..<count {
                let name = stateName(channel, index).map { $0.takeUnretainedValue() as String } ?? "\(index)"
                out.append((state: name, value: stateResidency(channel, index)))
            }
            return out
        }
        if isSimple(channel) {
            return [(state: "", value: simpleValue(channel, 0))]
        }
        return []
    }
}

/// 표본 한 칸 (1초 동안 늘어난 양과 지금 값)
struct IOReportValue {
    let key: String        // 그룹 / 하위 그룹 / 채널
    let state: String      // 상태 채널이면 상태 이름, 단순값이면 ""
    let delta: Int64
    let current: Int64
}

/// IOReport 그룹 하나를 구독한다. keep을 주면 그 이름의 채널만 (하나도 없으면 그룹 전체).
final class IOReportSubscription {
    let group: String
    let channelKeys: [String]
    private let library: IOReportLibrary
    private let subscription: OpaquePointer
    private let channels: CFMutableDictionary
    private var previous: CFDictionary

    init?(library: IOReportLibrary, group: String, keep: Set<String>?) {
        guard let found = library.copyChannelsInGroup(group as CFString, nil, 0, 0, 0)?.takeRetainedValue() else {
            return nil
        }
        var list = IOReportLibrary.channels(in: found)
        if let keep {
            let kept = list.filter { keep.contains(library.text(library.channelName, $0)) }
            if !kept.isEmpty {
                list = kept
            }
        }
        guard !list.isEmpty, let desired = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, found) else {
            return nil
        }
        (desired as NSMutableDictionary)["IOReportChannels"] = list as NSArray
        // 구독한 채널 사전의 소유 규칙은 문서가 없어서 놓지 않는다 (앱과 같음)
        var subscribed: Unmanaged<CFMutableDictionary>?
        guard let made = library.createSubscription(nil, desired, &subscribed, 0, nil),
              let subscribedChannels = subscribed?.takeUnretainedValue(),
              let first = library.createSamples(made, subscribedChannels, nil)?.takeRetainedValue() else {
            return nil
        }
        self.group = group
        self.library = library
        self.subscription = made
        self.channels = subscribedChannels
        self.previous = first
        self.channelKeys = IOReportLibrary.channels(in: first).map { library.key(of: $0) }
    }

    /// 지난번 뒤로 늘어난 양과 지금 값. 표본을 만들지 못하면 nil
    func sample() -> [IOReportValue]? {
        guard let current = library.createSamples(subscription, channels, nil)?.takeRetainedValue() else {
            return nil
        }
        defer { previous = current }
        guard let delta = library.createSamplesDelta(previous, current, nil)?.takeRetainedValue() else {
            return nil
        }
        var now: [String: Int64] = [:]
        for channel in IOReportLibrary.channels(in: current) {
            let key = library.key(of: channel)
            for v in library.values(of: channel) {
                now[key + "\t" + v.state] = v.value
            }
        }
        var out: [IOReportValue] = []
        for channel in IOReportLibrary.channels(in: delta) {
            let key = library.key(of: channel)
            for v in library.values(of: channel) {
                out.append(IOReportValue(key: key, state: v.state, delta: v.value, current: now[key + "\t" + v.state] ?? 0))
            }
        }
        return out
    }
}
