import AppIntents
import Foundation

/// 위젯의 '상세 보기/요약 보기' 버튼이 실행하는 동작이에요.
/// 화면 상태만 위젯 쪽에 저장하고, 공유 폴더의 측정 데이터는 건드리지 않아요.
struct ToggleDetailIntent: AppIntent {
    static let title: LocalizedStringResource = "위젯 상세 화면 전환"

    func perform() async throws -> some IntentResult {
        ProbeWidgetState.showDetail.toggle()
        return .result()
    }
}

/// 위젯 확장 자신의 설정에 저장하는 상태예요. (공유 폴더는 앱만 써요)
enum ProbeWidgetState {
    private static let showDetailKey = "showDetail"
    private static let renderTimesKey = "renderTimes"

    /// 위젯이 지금 상세 화면을 보여주는지
    static var showDetail: Bool {
        get { UserDefaults.standard.bool(forKey: showDetailKey) }
        set { UserDefaults.standard.set(newValue, forKey: showDetailKey) }
    }

    /// 위젯이 타임라인을 새로 만든 시각을 기록하고, 최근 갱신 간격(초)을 돌려줘요.
    static func recordRender(at date: Date) -> [TimeInterval] {
        var times = UserDefaults.standard.array(forKey: renderTimesKey) as? [Double] ?? []
        times.append(date.timeIntervalSince1970)
        if times.count > 9 {
            times.removeFirst(times.count - 9)
        }
        UserDefaults.standard.set(times, forKey: renderTimesKey)
        return intervals(between: times)
    }

    /// 기록은 남기지 않고 지금까지의 갱신 간격(초)만 읽어요.
    static var recentIntervals: [TimeInterval] {
        intervals(between: UserDefaults.standard.array(forKey: renderTimesKey) as? [Double] ?? [])
    }

    private static func intervals(between times: [Double]) -> [TimeInterval] {
        zip(times.dropFirst(), times).map { later, earlier in later - earlier }
    }
}
