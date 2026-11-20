import os

/// 보조 프로그램 기록 (macOS 통합 기록, 내용 공개). 디스크 추적 기록(diskActivity)과 같은 subsystem이에요.
/// 전에는 NSLog라 `log show`에서 내용이 <private>로 가려졌어요. (2026-11-21 실사용 점검을 위해 바꿈)
/// 보기: log show --last 1h --style compact --predicate 'subsystem == "com.seungheon.MonitorTool.helper"'
enum HelperLog {
    enum Category: String, CaseIterable {
        /// 시작·끝·연결
        case lifecycle
        /// powermetrics
        case power
        /// 팬 제어
        case fan
    }

    private static let loggers: [Category: Logger] = Dictionary(
        uniqueKeysWithValues: Category.allCases.map { ($0, Logger(subsystem: HelperConstants.label, category: $0.rawValue)) })

    static func notice(_ category: Category, _ message: String) {
        logger(category).notice("\(message, privacy: .public)")
    }

    static func error(_ category: Category, _ message: String) {
        logger(category).error("\(message, privacy: .public)")
    }

    private static func logger(_ category: Category) -> Logger {
        loggers[category] ?? Logger(subsystem: HelperConstants.label, category: category.rawValue)
    }
}
