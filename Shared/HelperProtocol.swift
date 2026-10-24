import Foundation

// 앱(MonitorTool)과 관리자 권한 보조 프로그램(MonitorToolHelper)이 함께 쓰는 약속이에요.
// 이 폴더(Shared)의 파일은 두 타깃에 모두 들어가요.
// 구조는 Diagnostics/HelperProbe에서 이 Mac(개인 팀 서명)으로 확인한 것과 같아요.

/// 앱과 보조 프로그램이 XPC로 주고받는 약속이에요.
/// 보조 프로그램은 여기 적힌 일만 하고, 임의의 명령이나 인자는 받지 않아요.
@objc(MonitorToolHelperProtocol)
nonisolated protocol HelperProtocol {
    /// 가장 최근 전력 표본을 돌려줘요. 앱이 묻는 동안 보조 프로그램은 powermetrics를 계속 돌려요.
    /// - Parameters:
    ///   - intervalMilliseconds: 원하는 측정 간격. 1,000(패널이 열려 있을 때)이나 10,000(닫혀 있을 때)만 받아요.
    ///   - reply: (PowerSample을 JSON으로 담은 값, 문제 설명). 첫 표본을 기다리는 중이거나
    ///     보조 프로그램이 새 버전으로 다시 뜨는 중이면 둘 다 nil이에요.
    func latestPower(intervalMilliseconds: Int, reply: @escaping (Data?, String?) -> Void)
}

/// 이름, 측정 간격, 서명 요구사항처럼 두 쪽이 똑같이 알아야 하는 값이에요.
nonisolated enum HelperConstants {
    /// launchd 작업 이름이자 XPC Mach 서비스 이름
    static let label = "com.seungheon.MonitorTool.helper"
    /// 앱 번들의 Contents/Library/LaunchDaemons 안에 넣는 plist 파일 이름
    static let plistName = "com.seungheon.MonitorTool.helper.plist"
    /// 앱 번들의 Contents/MacOS 안에 넣는 보조 프로그램 실행 파일 이름 (plist의 BundleProgram과 같아요)
    static let executableName = "MonitorToolHelper"
    /// 보조 프로그램이 연결을 받아 주는 앱
    static let appIdentifier = "com.seungheon.MonitorTool"
    /// 개인 팀(Personal Team) ID
    static let teamID = "47C8XKJT3X"

    /// 패널이 열려 있을 때 측정 간격 (밀리초)
    static let panelOpenInterval = 1_000
    /// 패널이 닫혀 있을 때 측정 간격 (밀리초)
    static let panelClosedInterval = 10_000
    /// 보조 프로그램이 받아 주는 측정 간격
    static let sampleIntervals = [panelOpenInterval, panelClosedInterval]

    /// 같은 팀이 서명한 코드인지 확인하는 서명 요구사항 (앱이 보조 프로그램을 확인할 때)
    static var teamRequirement: String {
        "anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\""
    }

    /// 보조 프로그램이 연결을 받아 줄 앱: 같은 팀이 서명한 MonitorTool
    static var appRequirement: String {
        "identifier \"\(appIdentifier)\" and \(teamRequirement)"
    }
}

/// 보조 프로그램이 앱에 넘기는 전력 표본 하나예요. 단위는 powermetrics와 같은 mW예요.
nonisolated struct PowerSample: Codable, Hashable, Sendable {
    /// CPU 전체 전력 (mW)
    var cpuMilliwatts: Double?
    /// GPU 전력 (mW). 앱은 GPU 전력을 보조 프로그램 없이 따로 읽을 거라(5단계) 지금은 쓰지 않아요.
    var gpuMilliwatts: Double?
    /// ANE 전력 (mW)
    var aneMilliwatts: Double?
    /// 표본 구간의 길이 (초)
    var interval: Double
    /// 표본을 받은 시각 (구간이 끝난 때)
    var measuredAt: Date
}
