// MonitorTool 관리자 권한 보조 프로그램 (LaunchDaemon)
//
// 앱이 SMAppService로 등록하고 사용자가 시스템 설정에서 허용하면, launchd가 관리자 권한(root)으로 실행해요.
// 같은 개발자(개인 팀)가 서명한 MonitorTool 앱의 XPC 요청만 받고,
// powermetrics로 CPU·GPU·ANE 전력을 재서 돌려주는 일, 팬을 고정·시스템 제어로 돌리는 일,
// 커널 추적으로 디스크 활성 시간을 재는 일만 해요.
// (설계 문서 6장, docs/FAN_CONTROL.md, docs/DISK_ACTIVE_TIME.md)

import Foundation

NSLog("MonitorToolHelper: 시작 (uid %d)", getuid())

let sampler = PowerSampler()
// 시작할 때 수동으로 남은 팬이 있으면 시스템 제어로 정리해요.
let fan = FanController()
// 강제 종료로 남은 커널 추적이 있으면 정리하고, 충돌해도 추적이 켜진 채 남지 않게 해 둬요. (docs/DISK_ACTIVE_TIME.md 3.3)
DiskActivityTracer.cleanUpLeftovers()
installCrashRelease()
let tracer = DiskActivityTracer()
let lifecycle = HelperLifecycle(sampler: sampler, fan: fan, tracer: tracer)

// launchd가 끝내라고 하면(앱에서 '끄기' 등) powermetrics도 같이 멈추고, 팬은 시스템 제어로 돌리고, 디스크 추적을 놓고 끝나요.
signal(SIGTERM, SIG_IGN)
let terminationSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
terminationSource.setEventHandler {
    NSLog("MonitorToolHelper: 끝내라는 신호를 받았어요")
    sampler.stop()
    fan.shutdown()
    tracer.shutdown()
    exit(0)
}
terminationSource.resume()

let listener = NSXPCListener(machServiceName: HelperConstants.label)
// 같은 팀이 서명한 MonitorTool 앱의 연결만 받아요. 요구사항에 맞지 않는 연결은 시스템이 끊어요.
listener.setConnectionCodeSigningRequirement(HelperConstants.appRequirement)
listener.delegate = lifecycle
listener.resume()

dispatchMain()
