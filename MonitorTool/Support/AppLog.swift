import Foundation
import os

/// 앱 기록 (macOS 통합 기록). Release로 설치해서 쓰는 동안에도 읽히도록 내용을 공개로 남겨요. Xcode 출력 창에도 그대로 보여요.
/// - 모으기: bash Scripts/collect-logs.sh (기록·충돌 보고서·버전을 build/logs/에 모아요)
/// - 바로 보기: log show --last 1h --style compact --predicate 'subsystem BEGINSWITH "com.seungheon.MonitorTool"'
/// - notice는 평소 기록(디스크에 며칠 남음), error는 문제예요. info·debug는 디스크에 남지 않아서 쓰지 않아요.
/// - 바뀔 때만 남겨요. 1초마다 되풀이되는 일은 남기지 않아요. (2026-11-21 실사용 점검)
nonisolated enum AppLog {
    nonisolated enum Category: String, Sendable, CaseIterable {
        /// 켜짐·끝남·잠자기·화면·자원
        case app
        /// 항목 값의 상태 바뀜 (ValueStateLog)
        case values
        /// 보조 프로그램 연결·상태 (앱 쪽)
        case helper
        /// 디스크 활성 시간 출처·SMART
        case disk
        /// 팬 제어 (앱 쪽)
        case fan
        /// 위젯 공유 파일
        case widget
        /// 단축키·배경 흐림
        case ui
    }

    static let subsystem = "com.seungheon.MonitorTool"

    private static let loggers: [Category: Logger] = Dictionary(
        uniqueKeysWithValues: Category.allCases.map { ($0, Logger(subsystem: subsystem, category: $0.rawValue)) })

    static func notice(_ category: Category, _ message: String) {
        logger(category).notice("\(message, privacy: .public)")
    }

    static func error(_ category: Category, _ message: String) {
        logger(category).error("\(message, privacy: .public)")
    }

    private static func logger(_ category: Category) -> Logger {
        loggers[category] ?? Logger(subsystem: subsystem, category: category.rawValue)
    }

    /// 기록용 시간 글 (예: 3시간 33분, 12분 5초, 40초)
    static func duration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "알 수 없음" }
        let total = Int(min(seconds, 1_000_000_000).rounded())
        let hours = total / 3600
        let minutes = total % 3600 / 60
        let rest = total % 60
        if hours > 0 { return "\(hours)시간 \(minutes)분" }
        if minutes > 0 { return "\(minutes)분 \(rest)초" }
        return "\(rest)초"
    }
}
