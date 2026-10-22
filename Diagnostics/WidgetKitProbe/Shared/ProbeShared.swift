import Foundation

/// 호스트 앱이 쓰고 위젯이 읽는 진단용 스냅샷이에요.
struct ProbeSnapshot: Codable {
    /// 앱이 몇 번째로 쓴 스냅샷인지
    var sequence: Int
    /// 앱이 이 스냅샷을 쓴 시각
    var writtenAt: Date
    /// 지금까지 앱이 위젯 갱신을 요청한 횟수
    var reloadRequests: Int
    /// 그래프 확인용 더미 값 (최근 60개)
    var series: [Double]
}

/// 앱과 위젯이 함께 쓰는 공유 폴더(App Group) 정보예요.
enum ProbeShared {
    /// macOS 방식의 App Group 이름 (팀 ID 접두어 + 이름). 두 타깃의 entitlements와 같아야 해요.
    static let appGroupID = "47C8XKJT3X.com.seungheon.WidgetKitProbe"

    static var snapshotURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID)?
            .appendingPathComponent("snapshot.json")
    }

    static func load() -> ProbeSnapshot? {
        guard let url = snapshotURL, let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ProbeSnapshot.self, from: data)
    }

    static func save(_ snapshot: ProbeSnapshot) throws {
        guard let url = snapshotURL else {
            throw CocoaError(.fileNoSuchFile)
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(snapshot).write(to: url, options: .atomic)
    }
}
