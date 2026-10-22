import AppKit
import NotificationCenter

/// 알림 센터 '오늘' 영역의 구형 위젯(Today 확장) 진단 화면이에요.
/// '펼치기'를 누르면 preferredContentSize 높이를 바꿔서, 알림 센터가 위젯 높이를 늘려 주는지 확인해요.
@objc(TodayViewController)
final class TodayViewController: NSViewController, NCWidgetProviding {
    private static let collapsedHeight: CGFloat = 90
    private static let expandedHeight: CGFloat = 260

    private var isExpanded = false
    private var detailLabel: NSTextField?
    private var toggleButton: NSButton?

    override func loadView() {
        NSLog("[TodayWidgetProbe] loadView")

        let title = NSTextField(labelWithString: "MonitorTool 위젯 진단")
        title.font = NSFont.boldSystemFont(ofSize: 13)

        let value = NSTextField(labelWithString: "CPU 12% · RAM 9.8/16 GB (더미 값)")

        let button = NSButton(title: "펼치기", target: self, action: #selector(toggleExpanded))

        let detail = NSTextField(wrappingLabelWithString:
            "펼친 상태예요. 위젯 높이가 늘어나고 아래 위젯이 밀려났다면, 이 Mac의 알림 센터가 구형 위젯의 높이 변경을 지원하는 거예요.")
        detail.isHidden = true

        let stack = NSStackView(views: [title, value, button, detail])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)

        detailLabel = detail
        toggleButton = button
        view = stack
        preferredContentSize = NSSize(width: 0, height: Self.collapsedHeight)
    }

    @objc private func toggleExpanded() {
        isExpanded.toggle()
        detailLabel?.isHidden = !isExpanded
        toggleButton?.title = isExpanded ? "접기" : "펼치기"

        let height = isExpanded ? Self.expandedHeight : Self.collapsedHeight
        preferredContentSize = NSSize(width: 0, height: height)

        let message = "[TodayWidgetProbe] expanded=\(isExpanded) requestedHeight=\(height) viewHeight=\(view.frame.height)"
        NSLog("%@", message)
    }

    // 알림 센터가 위젯 내용을 새로 그릴 때 불러요.
    nonisolated func widgetPerformUpdate(completionHandler: @escaping (NCUpdateResult) -> Void) {
        NSLog("[TodayWidgetProbe] widgetPerformUpdate")
        completionHandler(.newData)
    }
}
