import Foundation

/// 앱이 XPC로 부르는 일을 실제로 해요. 약속(HelperProtocol)에 적힌 일만 해요.
final class HelperService: NSObject, HelperProtocol {
    private let sampler: PowerSampler
    private let lifecycle: HelperLifecycle

    init(sampler: PowerSampler, lifecycle: HelperLifecycle) {
        self.sampler = sampler
        self.lifecycle = lifecycle
        super.init()
    }

    func latestPower(intervalMilliseconds: Int, reply: @escaping (Data?, String?) -> Void) {
        // 앱을 다시 빌드해서 보조 프로그램 파일이 바뀌었으면, 새 파일로 다시 뜨도록 끝내요.
        // 실패가 아니라서 '아직 값 없음'(둘 다 nil)으로 답해요. 앱의 다음 요청 때 launchd가 새 파일로 띄워요.
        if lifecycle.executableChanged {
            reply(nil, nil)
            lifecycle.exitSoon()
            return
        }
        let result = sampler.latest(intervalMilliseconds: intervalMilliseconds)
        let data = result.sample.flatMap { try? JSONEncoder().encode($0) }
        reply(data, result.problem)
    }
}

/// 연결을 받아 주고, 보조 프로그램이 언제 끝날지 정해요.
/// - 같은 팀이 서명한 MonitorTool 앱의 연결만 받아요. (서명 요구사항은 main.swift에서 걸어요)
/// - 앱이 모두 연결을 끊으면 5초 뒤에 끝나요. 앱이 다시 부르면 launchd가 다시 띄워요.
/// - 앱을 다시 빌드해서 실행 파일이 바뀌면 끝나요. 그래야 다음 연결 때 새 파일로 떠요.
final class HelperLifecycle: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.seungheon.MonitorTool.helper.lifecycle")
    private let sampler: PowerSampler
    private var connectionCount = 0
    private var pendingExit: DispatchWorkItem?
    private var exitIsForced = false

    /// 이 보조 프로그램 실행 파일의 위치와, 실행할 때의 수정 시각
    private let executablePath: String?
    private let launchedFileDate: Date?

    init(sampler: PowerSampler) {
        // super.init 전에는 self의 속성을 읽을 수 없어서, 지역 상수로 먼저 구해요.
        let path = Bundle.main.executableURL?.path
        self.sampler = sampler
        executablePath = path
        launchedFileDate = HelperLifecycle.modificationDate(of: path)
        super.init()
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(with: HelperProtocol.self)
        newConnection.exportedObject = HelperService(sampler: sampler, lifecycle: self)
        newConnection.invalidationHandler = { [weak self] in
            self?.connectionEnded()
        }
        queue.sync {
            connectionCount += 1
            // 끝내려고 기다리던 중이었다면 그만둬요. (실행 파일이 바뀌어서 끝내는 중이면 그대로 끝내요)
            if !exitIsForced {
                pendingExit?.cancel()
                pendingExit = nil
            }
        }
        newConnection.resume()
        NSLog("MonitorToolHelper: 연결 받음 (pid %d)", newConnection.processIdentifier)
        return true
    }

    /// 실행한 뒤에 실행 파일이 바뀌었는지 (앱을 다시 빌드하면 바뀌어요)
    var executableChanged: Bool {
        guard let launchedFileDate else { return false }
        return HelperLifecycle.modificationDate(of: executablePath) != launchedFileDate
    }

    /// 곧 끝내요. 연결이 남아 있어도 끝내고, 앱이 다시 부르면 launchd가 새 파일로 띄워요.
    func exitSoon() {
        queue.async {
            self.exitIsForced = true
            self.scheduleExit(after: 0.5)
        }
    }

    private func connectionEnded() {
        queue.async {
            self.connectionCount = max(self.connectionCount - 1, 0)
            if self.connectionCount == 0 {
                self.scheduleExit(after: 5)
            }
        }
    }

    /// queue 안에서만 불러요.
    private func scheduleExit(after seconds: Double) {
        pendingExit?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // 기다리는 동안 앱이 다시 연결했으면 끝내지 않아요.
            guard self.exitIsForced || self.connectionCount == 0 else { return }
            NSLog("MonitorToolHelper: 끝내요 (%@)", self.exitIsForced ? "실행 파일이 바뀜" : "연결 없음")
            self.sampler.stop()
            exit(0)
        }
        pendingExit = work
        queue.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private static func modificationDate(of path: String?) -> Date? {
        guard let path else { return nil }
        return (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }
}
