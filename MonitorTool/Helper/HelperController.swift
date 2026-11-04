import AppKit
import Foundation
import Observation
import ServiceManagement

/// 관리자 권한 보조 프로그램(LaunchDaemon)을 켜고 끄고, XPC로 CPU·ANE 전력을 받아 와요.
/// 구조는 Diagnostics/HelperProbe에서 이 Mac(개인 팀 서명)으로 확인한 것과 같아요. (설계 문서 6·7장)
@Observable
final class HelperController {
    /// 지금 상태예요. 설정 창의 '보조 프로그램' 탭과 패널이 봐요.
    private(set) var status: HelperStatus = .unknown
    /// 허용됐는데도 값을 받지 못한 이유예요. 있으면 상태가 '연결 실패'가 돼요.
    private(set) var problem: String?
    /// 켜기·끄기가 실패했을 때 보여줄 글
    private(set) var actionMessage: String?
    /// 가장 최근에 받은 전력 표본
    private(set) var latestSample: PowerSample?
    /// 지금 요청하는 측정 간격 (밀리초). 패널이 열려 있으면 1초, 닫혀 있으면 10초예요.
    private(set) var intervalMilliseconds = HelperConstants.panelClosedInterval
    /// 끄는 중이에요. (단추를 잠깐 막아요)
    private(set) var isBusy = false

    /// 상태나 값이 바뀌면 불러요. 수집 일정(CollectionScheduler)이 패널 값을 새로 만들어요.
    @ObservationIgnored var onChange: (() -> Void)?

    @ObservationIgnored private let service = SMAppService.daemon(plistName: HelperConstants.plistName)
    @ObservationIgnored private var connection: NSXPCConnection?
    /// 답을 기다리는 요청 (번호와 보낸 시각)
    @ObservationIgnored private var pending: (id: UUID, sentAt: Date)?
    @ObservationIgnored private var lastStatusCheck = Date.distantPast
    @ObservationIgnored private var activationObserver: (any NSObjectProtocol)?
    /// 미리보기에서는 macOS에 묻지 않아요.
    @ObservationIgnored private var isPreview = false

    /// 실패가 이어지기 시작한 시각이에요. 한 번이라도 답을 받으면 지워요.
    @ObservationIgnored private var failingSince: Date?
    /// macOS가 앱 안에서 보조 프로그램을 찾지 못했다고 알려 줬어요. (다시 빌드해야 해요)
    @ObservationIgnored private var isMissingFromApp = false

    /// 답을 이만큼 기다려도 오지 않으면 연결을 끊고 실패로 봐요. (초)
    private static let replyTimeout: TimeInterval = 5
    /// 실패가 이만큼 이어질 때만 '연결 실패'로 보여줘요. (초)
    /// 앱을 다시 빌드하면 보조 프로그램이 새 버전으로 다시 뜨는데, 그 몇 초를 실패로 보이지 않으려고요.
    private static let failureGrace: TimeInterval = 4

    init() {
        // 시스템 설정에서 허용하고 돌아오면 상태가 바뀌어 있어요. 앱으로 돌아올 때마다 다시 물어봐요.
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshStatus()
            }
        }
    }

    // MARK: - 등록 상태

    /// macOS에 등록·허용 상태를 다시 물어봐요.
    func refreshStatus() {
        guard !isPreview else { return }
        lastStatusCheck = Date()
        let serviceStatus = service.status
        isMissingFromApp = false
        switch serviceStatus {
        case .notRegistered:
            stopReceiving()
            setStatus(.notRegistered)
        case .requiresApproval:
            stopReceiving()
            setStatus(.requiresApproval)
        case .enabled:
            setStatus(problem == nil ? .enabled : .failed)
        case .notFound:
            // macOS는 한 번도 등록하지 않은 보조 프로그램을 '찾을 수 없음'으로 알려요. (2026-10-24 이 Mac에서 확인)
            // 앱 안에 파일이 다 있으면 아직 켜지 않은 거라 '꺼짐'으로 보여요. 파일이 빠졌을 때만 빌드 문제예요.
            stopReceiving()
            if let missing = HelperController.missingBundleFile() {
                isMissingFromApp = true
                setProblem("앱 안에 보조 프로그램 파일(\(missing))이 없어요. Xcode에서 다시 빌드해 주세요.")
                setStatus(.failed)
            } else {
                setStatus(.notRegistered)
            }
        @unknown default:
            setProblem("macOS가 알 수 없는 상태를 알려 줬어요. (\(serviceStatus.rawValue))")
            setStatus(.failed)
        }
    }

    /// 상태를 너무 자주 묻지 않게 해요. macOS에 한 번 묻는 데 20 ms쯤 걸려요. (2026-10-25 이 Mac에서 잼)
    /// 패널이 열려 있으면 허용을 기다리거나 실패한 동안은 2초, 꺼져 있으면 10초마다 물어요.
    /// 잘 동작하는 동안(5분, 끊기면 XPC 오류로 바로 알아채요)이나 패널이 닫혀 있을 때는 드물게 물어요. 값을 받다가 실패가 이어져
    /// '연결 실패'가 되면 2초(닫혀 있으면 10초)마다 다시 물어요.
    func refreshStatusIfDue(panelVisible: Bool = true) {
        let wait: TimeInterval
        switch status {
        case .unknown:
            wait = 2
        case .requiresApproval:
            wait = panelVisible ? 2 : 60
        case .failed:
            wait = panelVisible ? 2 : 10
        case .notRegistered:
            wait = panelVisible ? 10 : 60
        case .enabled:
            wait = 300
        }
        if Date().timeIntervalSince(lastStatusCheck) >= wait {
            refreshStatus()
        }
    }

    /// 보조 프로그램을 등록해요. 처음에는 시스템 설정에서 허용해야 해서 '허용 필요'가 돼요.
    func turnOn() {
        guard !isPreview else { return }
        actionMessage = nil
        do {
            try service.register()
            refreshStatus()
        } catch {
            // 처음 등록하면 'Operation not permitted'(오류 1)와 함께 허용을 기다리는 상태가 돼요.
            // 실패가 아니라 허용 안내로 처리하고, 정말 실패했는지는 등록 상태로 판단해요. (Diagnostics/HelperProbe)
            refreshStatus()
            if status != .requiresApproval && status != .enabled {
                actionMessage = "켜지 못했어요. (\(HelperController.describe(error)))"
            }
        }
    }

    /// 등록을 해제해요. launchd가 보조 프로그램을 멈추고, powermetrics도 같이 멈춰요.
    func turnOff() {
        guard !isPreview, !isBusy else { return }
        isBusy = true
        actionMessage = nil
        stopReceiving()
        Task {
            do {
                try await service.unregister()
            } catch {
                actionMessage = "끄지 못했어요. (\(HelperController.describe(error)))"
            }
            isBusy = false
            setProblem(nil)
            refreshStatus()
        }
    }

    /// 시스템 설정의 로그인 항목 화면(백그라운드에서 허용)을 열어요.
    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    /// 패널의 '보조 프로그램 허용하기' 단추: 꺼져 있으면 켜고, 허용이 필요하면 시스템 설정을 열어요.
    func allow() {
        refreshStatus()
        if status == .notRegistered {
            turnOn()
        }
        if status == .requiresApproval {
            openSystemSettings()
        }
    }

    /// '다시 시도': 연결을 새로 만들고 바로 다시 물어봐요.
    func retry() {
        dropConnection()
        failingSince = nil
        setProblem(nil)
        refreshStatus()
        if status == .enabled {
            requestPower(intervalMilliseconds: intervalMilliseconds)
        }
    }

    // MARK: - 전력 받기

    /// 보조 프로그램에 가장 최근 전력 표본을 달라고 해요.
    /// 답은 메인 스레드에서 처리하고, 바뀐 것이 있으면 onChange로 알려요.
    func requestPower(intervalMilliseconds interval: Int) {
        guard !isPreview else { return }
        if intervalMilliseconds != interval {
            intervalMilliseconds = interval
        }
        // 끄는 중이거나 앱 안에 보조 프로그램이 없으면 묻지 않아요.
        guard !isBusy, !isMissingFromApp, status == .enabled || status == .failed else { return }

        if let pending {
            // 앞 요청의 답을 기다리는 중이에요. 너무 오래 걸리면 연결을 끊고 실패로 봐요.
            guard Date().timeIntervalSince(pending.sentAt) > HelperController.replyTimeout else { return }
            dropConnection()
            fail("보조 프로그램이 응답하지 않아요. 다시 시도해 보세요.", startedAt: pending.sentAt)
            return
        }

        let id = UUID()
        pending = (id, Date())
        let connection = self.connection ?? makeConnection()
        self.connection = connection
        // 답과 오류는 XPC가 다른 스레드에서 불러요. 메인 스레드로 옮겨서 처리해요.
        let proxy = connection.remoteObjectProxyWithErrorHandler { @Sendable [weak self] error in
            guard let self else { return }
            Task { @MainActor in
                self.requestFailed(id: id, error: error)
            }
        }
        guard let helper = proxy as? HelperProtocol else {
            pending = nil
            fail("보조 프로그램 연결을 만들지 못했어요.")
            return
        }
        helper.latestPower(intervalMilliseconds: interval) { @Sendable [weak self] data, helperProblem in
            guard let self else { return }
            Task { @MainActor in
                self.received(id: id, data: data, helperProblem: helperProblem)
            }
        }
    }

    private func received(id: UUID, data: Data?, helperProblem: String?) {
        // 연결을 다시 만든 뒤에 늦게 온 답은 버려요.
        guard pending?.id == id else { return }
        pending = nil
        if let helperProblem {
            fail(helperProblem)
            return
        }
        var sample: PowerSample?
        if let data {
            guard let decoded = try? JSONDecoder().decode(PowerSample.self, from: data) else {
                fail("보조 프로그램이 보낸 값을 읽지 못했어요.")
                return
            }
            sample = decoded
        }
        failingSince = nil
        setProblem(nil)
        setStatus(.enabled)
        // 값이 없으면 보조 프로그램이 첫 표본을 기다리는 중이에요. (측정 준비 중)
        if let sample {
            setSample(sample)
        }
    }

    private func requestFailed(id: UUID, error: any Error) {
        guard pending?.id == id else { return }
        dropConnection()
        fail("보조 프로그램과 연결하지 못했어요. (\(HelperController.describe(error)))")
    }

    /// - Parameter startedAt: 이 실패가 시작된 때 (답을 기다리다 시간이 다 된 경우에는 요청을 보낸 때)
    private func fail(_ message: String, startedAt: Date = Date()) {
        let since = failingSince ?? startedAt
        failingSince = since
        // 잠깐의 실패는 넘기고, 이어질 때만 이유를 보여줘요. 그동안 값은 '측정 준비 중'으로 보여요.
        if status != .enabled || Date().timeIntervalSince(since) >= HelperController.failureGrace {
            setProblem(message)
            if status == .enabled {
                setStatus(.failed)
            }
        }
        // 시스템 설정에서 허용을 껐을 수도 있어요. 등록 상태를 다시 확인해요. (너무 자주 묻지는 않아요)
        refreshStatusIfDue()
    }

    // MARK: - 팬 제어 (docs/FAN_CONTROL.md)

    /// 보조 프로그램에 팬 고정이나 시스템 제어를 요청해요. 답(상태, 거절·실패 이유)은 메인 스레드에서 받아요.
    func sendFanControl(_ request: FanControlRequest,
                        completion: @escaping @MainActor @Sendable (FanControlState?, String?) -> Void) {
        guard let data = try? JSONEncoder().encode(request) else {
            completion(nil, "요청 형식 오류")
            return
        }
        callFanService(completion: completion) { helper, reply in
            helper.setFanControl(data, reply: reply)
        }
    }

    /// 보조 프로그램에 지금 팬 제어 상태를 물어요.
    func fetchFanState(completion: @escaping @MainActor @Sendable (FanControlState?, String?) -> Void) {
        callFanService(completion: completion) { helper, reply in
            helper.fanControlState(reply: reply)
        }
    }

    /// 전력 요청과 같은 연결을 써요. 앱이 꺼져 이 연결이 끊기면 보조 프로그램이 팬을 시스템 제어로 돌려요.
    private func callFanService(completion: @escaping @MainActor @Sendable (FanControlState?, String?) -> Void,
                                call: (HelperProtocol, @escaping @Sendable (Data?, String?) -> Void) -> Void) {
        guard !isPreview else {
            completion(nil, nil)
            return
        }
        guard status == .enabled || status == .failed, !isMissingFromApp, !isBusy else {
            completion(nil, "보조 프로그램 허용 필요")
            return
        }
        let connection = self.connection ?? makeConnection()
        self.connection = connection
        let proxy = connection.remoteObjectProxyWithErrorHandler { @Sendable _ in
            Task { @MainActor in
                completion(nil, "보조 프로그램 연결 실패")
            }
        }
        guard let helper = proxy as? HelperProtocol else {
            completion(nil, "보조 프로그램 연결 실패")
            return
        }
        call(helper) { @Sendable data, helperProblem in
            let state = data.flatMap { try? JSONDecoder().decode(FanControlState.self, from: $0) }
            Task { @MainActor in
                completion(state, helperProblem)
            }
        }
    }

    // MARK: - 연결

    private func makeConnection() -> NSXPCConnection {
        // .privileged: 시스템 영역(LaunchDaemon)에 있는 서비스에 연결해요.
        let connection = NSXPCConnection(machServiceName: HelperConstants.label, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: HelperProtocol.self)
        // 같은 개발자(개인 팀)가 서명한 보조 프로그램에만 말을 걸어요.
        connection.setCodeSigningRequirement(HelperConstants.teamRequirement)
        let connectionID = ObjectIdentifier(connection)
        connection.invalidationHandler = { @Sendable [weak self] in
            guard let self else { return }
            Task { @MainActor in
                self.connectionInvalidated(connectionID)
            }
        }
        connection.resume()
        return connection
    }

    private func connectionInvalidated(_ connectionID: ObjectIdentifier) {
        // 이미 새 연결로 바꿨다면 그대로 둬요.
        guard let connection, ObjectIdentifier(connection) == connectionID else { return }
        self.connection = nil
        pending = nil
    }

    /// 연결을 끊어요. 다음 요청 때 새로 연결해요.
    private func dropConnection() {
        connection?.invalidate()
        connection = nil
        pending = nil
    }

    /// 꺼지거나 허용이 풀리면 연결을 끊고, 받았던 값도 지워요.
    private func stopReceiving() {
        dropConnection()
        failingSince = nil
        setProblem(nil)
        setSample(nil)
    }

    // MARK: - 값 바꾸기 (바뀐 것이 있을 때만 화면에 알려요)

    private func setStatus(_ newStatus: HelperStatus) {
        guard status != newStatus else { return }
        status = newStatus
        // 상태가 바뀌면 앞서 실패했던 켜기·끄기 안내는 지워요.
        actionMessage = nil
        onChange?()
    }

    private func setProblem(_ newProblem: String?) {
        guard problem != newProblem else { return }
        problem = newProblem
        if let newProblem {
            // Xcode 아래쪽 출력 창에도 남겨요. 원인을 찾을 때 복사해서 보내 주세요.
            print("⚠️ 보조 프로그램: \(newProblem)")
        }
        onChange?()
    }

    private func setSample(_ newSample: PowerSample?) {
        guard latestSample != newSample else { return }
        latestSample = newSample
        onChange?()
    }

    /// 앱 안에 보조 프로그램 파일이 다 들어 있는지 봐요. 빠진 파일의 앱 안 경로를 돌려줘요. (다 있으면 nil)
    private static func missingBundleFile() -> String? {
        let paths = ["Contents/Library/LaunchDaemons/\(HelperConstants.plistName)",
                     "Contents/MacOS/\(HelperConstants.executableName)"]
        return paths.first { path in
            let url = Bundle.main.bundleURL.appending(path: path)
            return !FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
        }
    }

    /// 오류를 짧은 한 줄로 바꿔요. 원인을 찾기 쉽게 도메인과 번호를 붙여요.
    private static func describe(_ error: any Error) -> String {
        let nsError = error as NSError
        return "\(nsError.localizedDescription) [\(nsError.domain) \(nsError.code)]"
    }
}

#if DEBUG
extension HelperController {
    /// 미리보기용: macOS에 묻지 않고 정해진 상태를 보여줘요.
    // periphery:ignore - 미리보기(#Preview)에서 써요.
    static func preview(_ status: HelperStatus,
                        problem: String? = nil,
                        sample: PowerSample? = nil,
                        intervalMilliseconds: Int = HelperConstants.panelOpenInterval) -> HelperController {
        let controller = HelperController()
        controller.isPreview = true
        controller.status = status
        controller.problem = problem
        controller.latestSample = sample
        controller.intervalMilliseconds = intervalMilliseconds
        return controller
    }
}
#endif
