import Charts
import SwiftUI
import WidgetKit

/// 위젯을 한 번 그릴 때 쓰는 값이에요.
struct ProbeEntry: TimelineEntry {
    /// 위젯이 이 화면을 만든 시각
    let date: Date
    /// 앱이 공유 폴더에 쓴 마지막 스냅샷 (못 읽으면 nil)
    let snapshot: ProbeSnapshot?
    let showDetail: Bool
    /// 최근 타임라인 갱신 사이의 간격(초)
    let recentIntervals: [TimeInterval]
}

struct ProbeProvider: TimelineProvider {
    func placeholder(in context: Context) -> ProbeEntry {
        ProbeEntry(date: .now, snapshot: nil, showDetail: false, recentIntervals: [])
    }

    func getSnapshot(in context: Context, completion: @escaping (ProbeEntry) -> Void) {
        completion(makeEntry(recordsRender: false))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ProbeEntry>) -> Void) {
        // 1분 뒤 갱신을 요청하지만 실제 간격은 WidgetKit이 정해요. 그 간격을 재는 게 이 진단의 목적이에요.
        let next = Date.now.addingTimeInterval(60)
        completion(Timeline(entries: [makeEntry(recordsRender: true)], policy: .after(next)))
    }

    /// recordsRender가 true면 이번 갱신 시각을 기록해요. (위젯 갤러리 미리보기는 기록하지 않음)
    private func makeEntry(recordsRender: Bool) -> ProbeEntry {
        let now = Date.now
        let intervals = recordsRender
            ? ProbeWidgetState.recordRender(at: now)
            : ProbeWidgetState.recentIntervals
        return ProbeEntry(date: now,
                          snapshot: ProbeShared.load(),
                          showDetail: ProbeWidgetState.showDetail,
                          recentIntervals: intervals)
    }
}

struct ProbeWidgetView: View {
    let entry: ProbeEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(entry.showDetail ? "상세" : "요약")
                    .font(.headline)
                Spacer()
                Button(intent: ToggleDetailIntent()) {
                    Text(entry.showDetail ? "요약 보기" : "상세 보기")
                }
            }

            if let snapshot = entry.snapshot {
                if entry.showDetail {
                    Chart(Array(snapshot.series.enumerated()), id: \.offset) { point in
                        LineMark(x: .value("순서", point.offset),
                                 y: .value("값", point.element))
                    }
                    .chartYScale(domain: 0...100)
                } else {
                    Text("쓴 횟수 \(snapshot.sequence)")
                        .font(.title3.monospacedDigit())
                    Text("앱이 쓴 시각 \(snapshot.writtenAt.formatted(date: .omitted, time: .standard)) · 앱 \(hostStateText(snapshot.hostWasActive))")
                        .font(.caption)
                    Text("갱신 요청 \(snapshot.reloadRequests)회")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("최근 갱신 간격(초) \(intervalsText)")
                        .font(.caption.monospacedDigit())
                }
            } else {
                Text("공유 데이터를 읽지 못했어요 (App Group 확인 필요)")
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            Text("위젯이 그린 시각 \(entry.date.formatted(date: .omitted, time: .standard))")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .containerBackground(.background, for: .widget)
    }

    /// 최근 간격을 최대 6개까지 "10 · 9 · 11"처럼 보여줘요.
    private var intervalsText: String {
        let recent = entry.recentIntervals.suffix(6)
        guard !recent.isEmpty else { return "-" }
        return recent.map { String(Int($0.rounded())) }.joined(separator: " · ")
    }

    private func hostStateText(_ isActive: Bool?) -> String {
        switch isActive {
        case true?: "맨 앞"
        case false?: "뒤"
        case nil: "?"
        }
    }
}

struct ProbeWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "WidgetKitProbe", provider: ProbeProvider()) { entry in
            ProbeWidgetView(entry: entry)
        }
        .configurationDisplayName("MonitorTool WidgetKit Probe")
        .description("위젯 갱신 간격과 위젯 안 화면 전환을 확인하는 진단용 위젯")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}
