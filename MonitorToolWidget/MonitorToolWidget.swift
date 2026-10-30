import SwiftUI
import WidgetKit

/// 위젯 확장의 시작점이에요. 요약 위젯(중간·큰) 하나와 항목별 그래프 위젯(작은) 넷이에요. (docs/WIDGET_V2.md)
@main
struct MonitorToolWidgetBundle: WidgetBundle {
    var body: some Widget {
        MonitorToolWidget()
        UsageGraphWidget()
        PowerGraphWidget()
        TemperatureGraphWidget()
        FanGraphWidget()
        NetworkGraphWidget()
        BatteryGraphWidget()
    }
}

struct MonitorToolWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetSharedFile.widgetKind, provider: MonitorProvider()) { entry in
            MonitorWidgetView(entry: entry)
                // 시스템 배경 위에 패널과 같은 반투명 카드를 그려요. 투명·색조 스타일에서는 macOS가 배경을 바꿔요.
                .containerBackground(.background, for: .widget)
        }
        .configurationDisplayName("MonitorTool")
        .description("CPU·GPU·ANE, 메모리, 온도·팬, 배터리, 네트워크")
        .supportedFamilies([.systemMedium, .systemLarge])
        .contentMarginsDisabled()
        .containerBackgroundRemovable(true)
    }
}

// MARK: - 타임라인

/// 위젯 전체 상태예요. 맨 위 줄 배지와 흐리게 보여줄지를 정해요. (docs/WIDGET_V2.md 3장)
enum WidgetStatus: Equatable {
    /// 새 값
    case live
    /// 마지막 저장 뒤 오래됨
    case stale
    /// 앱이 잠들기 직전에 남긴 값
    case sleeping
    /// 앱이 끝날 때 남긴 값
    case quit
    /// 공유 파일 없음
    case noData

    var badge: String? {
        switch self {
        case .live: nil
        case .stale: "오래됨"
        case .sleeping: "잠자기"
        case .quit: "앱 꺼짐"
        case .noData: "앱 꺼짐 · 기록 없음"
        }
    }

    /// 지금 값처럼 보이지 않게 흐리게 그릴지
    var dims: Bool {
        self != .live
    }
}

struct MonitorEntry: TimelineEntry {
    let date: Date
    let payload: WidgetPayload?

    var status: WidgetStatus {
        guard let payload else { return .noData }
        switch payload.appState {
        case .quit:
            return .quit
        case .sleeping:
            return .sleeping
        case .running:
            return date.timeIntervalSince(payload.savedAt) > WidgetPayload.staleLimit ? .stale : .live
        }
    }
}

struct MonitorProvider: TimelineProvider {
    func placeholder(in context: Context) -> MonitorEntry {
        MonitorEntry(date: Date(), payload: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (MonitorEntry) -> Void) {
        completion(entry(at: Date()))
    }

    /// 지금 항목과, 새 값이 오지 않으면 '오래됨'으로 바뀌는 항목을 함께 넘겨요.
    /// 새 값은 앱이 저장한 뒤 갱신을 부탁하므로 위젯이 스스로 다시 읽지는 않아요.
    func getTimeline(in context: Context, completion: @escaping (Timeline<MonitorEntry>) -> Void) {
        let now = Date()
        let current = entry(at: now)
        var entries = [current]
        if let payload = current.payload, payload.appState == .running {
            let staleAt = payload.savedAt.addingTimeInterval(WidgetPayload.staleLimit + 1)
            if staleAt > now {
                entries.append(entry(at: staleAt, payload: payload))
            }
        }
        completion(Timeline(entries: entries, policy: .never))
    }

    private func entry(at date: Date, payload: WidgetPayload? = WidgetSharedFile.read()) -> MonitorEntry {
        MonitorEntry(date: date, payload: payload)
    }
}
