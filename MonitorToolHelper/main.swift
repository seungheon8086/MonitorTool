// MonitorTool 관리자 권한 보조 프로그램 (LaunchDaemon)
//
// 앱이 SMAppService로 등록하고 사용자가 시스템 설정에서 허용하면, launchd가 관리자 권한(root)으로 실행해요.
// 같은 개발자(개인 팀)가 서명한 MonitorTool 앱의 XPC 요청만 받고,
// powermetrics로 CPU·GPU·ANE 전력을 재서 돌려주는 일만 해요. (설계 문서 6장)

import Foundation

NSLog("MonitorToolHelper: 시작 (uid %d)", getuid())

let sampler = PowerSampler()
let lifecycle = HelperLifecycle(sampler: sampler)

// launchd가 끝내라고 하면(앱에서 '끄기' 등) powermetrics도 같이 멈추고 끝나요.
signal(SIGTERM, SIG_IGN)
let terminationSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
terminationSource.setEventHandler {
    NSLog("MonitorToolHelper: 끝내라는 신호를 받았어요")
    sampler.stop()
    exit(0)
}
terminationSource.resume()

let listener = NSXPCListener(machServiceName: HelperConstants.label)
// 같은 팀이 서명한 MonitorTool 앱의 연결만 받아요. 요구사항에 맞지 않는 연결은 시스템이 끊어요.
listener.setConnectionCodeSigningRequirement(HelperConstants.appRequirement)
listener.delegate = lifecycle
listener.resume()

dispatchMain()
