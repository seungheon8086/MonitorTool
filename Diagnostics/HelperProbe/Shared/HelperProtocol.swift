import Foundation

/// 앱과 관리자 권한 보조 프로그램이 XPC로 주고받는 약속이에요.
/// 보조 프로그램은 여기 적힌 정해진 일만 하고, 임의의 명령은 받지 않아요.
@objc(HelperProbeProtocol)
protocol HelperProtocol {
    /// 보조 프로그램이 어떤 권한(uid)으로 돌고 있는지 알려줘요.
    func identity(reply: @escaping (String) -> Void)

    /// powermetrics를 정해진 인자로 한 번(1초) 실행해서 CPU·GPU·ANE 전력(mW)을 돌려줘요.
    /// 실패하면 값 대신 오류 설명을 돌려줘요.
    func samplePower(reply: @escaping ([String: NSNumber]?, String?) -> Void)
}

enum HelperConstants {
    /// launchd 작업 이름이자 XPC Mach 서비스 이름
    static let label = "com.seungheon.HelperProbe.daemon"
    /// 앱 번들의 Contents/Library/LaunchDaemons 안에 넣는 plist 파일 이름
    static let plistName = "com.seungheon.HelperProbe.daemon.plist"
    static let appIdentifier = "com.seungheon.HelperProbe"
    static let teamID = "47C8XKJT3X"

    /// 같은 팀(개인 팀)이 서명한 코드인지 확인하는 서명 요구사항
    static var teamRequirement: String {
        "anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\""
    }

    /// 보조 프로그램이 연결을 받아 줄 앱: 같은 팀이 서명한 HelperProbe 앱
    static var appRequirement: String {
        "identifier \"\(appIdentifier)\" and \(teamRequirement)"
    }
}
