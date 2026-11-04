import Foundation

// 앱이 위젯에 넘기는 값이에요. 앱과 위젯 확장이 함께 컴파일해요. (docs/WIDGET_V2.md 4장)

/// 앱이 지금 어떤 상태인지예요. 위젯 맨 위 줄 배지에 써요.
nonisolated enum WidgetAppState: String, Codable, Sendable {
    /// 값을 모으는 중
    case running
    /// 잠들기 직전에 남김
    case sleeping
    /// 앱이 끝날 때 남김
    case quit
}

/// 위젯 그래프에 그리는 계열이에요.
nonisolated enum WidgetSeriesKey: String, Codable, Sendable, CaseIterable {
    case cpuEfficiency, cpuPerformance, gpuUsage
    case cpuPower, gpuPower, anePower
    case cpuTemperature, gpuTemperature
    case networkDownload, networkUpload
    /// 팬 회전수 (SMC 0번 = 왼쪽, 1번 = 오른쪽)
    case fan0, fan1
    /// 배터리 순전력 (+ 충전, − 방전)
    case batteryNetPower
}

/// 위젯 공유 파일 하나의 내용이에요.
nonisolated struct WidgetPayload: Codable, Sendable {
    /// 형식이 바뀌면 올려요. 다른 판은 읽지 않아요.
    static let currentVersion = 1
    /// 그래프 칸 수와 칸 하나의 길이 (60칸 × 10초 = 10분)
    static let bucketCount = 60
    static let bucketSeconds: TimeInterval = 10
    /// 마지막 저장 뒤 이보다 오래되면 '오래됨'으로 보여줘요. (앱은 10초에 한 번 저장해요)
    static let staleLimit: TimeInterval = 45

    var version = WidgetPayload.currentVersion
    /// 이 파일을 쓴 시각
    var savedAt: Date
    var appState: WidgetAppState
    var snapshot: MonitorSnapshot
    /// 항목 색 (MonitorItem.rawValue → ItemColor.rawValue)
    var colors: [String: String]
    /// 계열별 값 (WidgetSeriesKey.rawValue → 오래된 칸부터 bucketCount개, 값이 없는 칸은 nil)
    var series: [String: [Double?]]

    /// 한 계열의 칸 값. 없으면 빈 칸들을 돌려줘요.
    func values(_ key: WidgetSeriesKey) -> [Double?] {
        let list = series[key.rawValue] ?? []
        guard list.count == WidgetPayload.bucketCount else {
            return Array(repeating: nil, count: WidgetPayload.bucketCount)
        }
        return list
    }
}

/// App Group 안의 공유 파일을 읽고 써요. 쓰는 쪽은 앱, 읽는 쪽은 위젯이에요.
nonisolated enum WidgetSharedFile {
    /// 개인 팀 접두어 방식의 App Group (앱·위젯 entitlements와 같아야 해요)
    static let appGroupID = "47C8XKJT3X.com.seungheon.MonitorTool"
    /// 요약 위젯 종류 이름 (그래프 위젯은 MonitorToolGraph.<항목>)
    static let widgetKind = "MonitorToolWidget"

    static var fileURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)?
            .appending(path: "Library/Application Support/widget-v2.json")
    }

    /// 다 쓴 뒤 한 번에 바꿔 넣어서, 위젯이 반쯤 쓴 파일을 읽지 않게 해요.
    static func write(_ payload: WidgetPayload) throws {
        guard let url = fileURL else {
            throw CocoaError(.fileNoSuchFile)
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(payload)
        try data.write(to: url, options: .atomic)
    }

    /// 파일이 없거나 판이 다르면 nil이에요.
    static func read() -> WidgetPayload? {
        guard let url = fileURL, let data = try? Data(contentsOf: url),
              let payload = try? JSONDecoder().decode(WidgetPayload.self, from: data),
              payload.version == WidgetPayload.currentVersion else {
            return nil
        }
        return payload
    }
}
