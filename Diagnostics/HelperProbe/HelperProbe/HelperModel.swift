import AppKit
import Foundation
import Observation
import ServiceManagement

/// 보조 프로그램 등록·해제와 XPC 호출을 맡아요. 진행 상황은 화면의 기록에 남겨요.
/// 기록은 앱을 다시 실행해도 이어져요. 디버거를 붙인 실행과 비교한 뒤 한 번에 복사하려고요.
@MainActor
@Observable
final class HelperModel {
    private(set) var statusText = "-"
    private(set) var signingText = "-"
    private(set) var lines: [String] = []

    @ObservationIgnored private let service = SMAppService.daemon(plistName: HelperConstants.plistName)
    @ObservationIgnored private var connection: NSXPCConnection?

    private static let logKey = "HelperProbeLog"

    init() {
        lines = UserDefaults.standard.stringArray(forKey: Self.logKey) ?? []
        if !lines.isEmpty {
            lines.append("──────── 앱 다시 실행 ────────")
        }
        log("앱 시작. 앱 서명: \(codeSigningSummary())")
    }

    func refreshStatus() {
        signingText = codeSigningSummary()
        switch service.status {
        case .notRegistered:
            statusText = "등록 안 됨"
        case .enabled:
            statusText = "사용 중 (허용됨)"
        case .requiresApproval:
            statusText = "허용 필요 (시스템 설정 → 일반 → 로그인 항목)"
        case .notFound:
            statusText = "찾을 수 없음 (앱 안의 plist·실행 파일 위치 확인 필요)"
        @unknown default:
            statusText = "알 수 없음 (\(service.status.rawValue))"
        }
    }

    func register() {
        do {
            try service.register()
            log("등록 요청 성공")
        } catch {
            log("등록 요청 결과: \(describe(error))")
        }
        refreshStatus()
        log("지금 상태: \(statusText)")
    }

    func unregister() {
        dropConnection()
        Task {
            do {
                try await service.unregister()
                log("등록 해제 성공")
            } catch {
                log("등록 해제 실패: \(describe(error))")
            }
            refreshStatus()
            log("지금 상태: \(statusText)")
        }
    }

    func openSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    func askIdentity() {
        guard let proxy = makeProxy() else { return }
        log("보조 프로그램에 권한을 물어봐요… (앱 서명: \(codeSigningSummary()))")
        proxy.identity { [weak self] text in
            Task { @MainActor in
                self?.log("보조 프로그램 응답: \(text)")
            }
        }
    }

    func samplePower() {
        guard let proxy = makeProxy() else { return }
        log("보조 프로그램에 전력 측정을 요청해요… 1초쯤 걸려요 (앱 서명: \(codeSigningSummary()))")
        let started = Date()
        proxy.samplePower { [weak self] values, errorText in
            let elapsed = Date().timeIntervalSince(started)
            Task { @MainActor in
                guard let self else { return }
                if let values {
                    let text = ["cpu_power", "gpu_power", "ane_power", "combined_power"]
                        .compactMap { key in values[key].map { "\(key) \(Int($0.doubleValue.rounded())) mW" } }
                        .joined(separator: ", ")
                    self.log("측정 결과 (응답까지 \(String(format: "%.1f", elapsed))초): \(text)")
                } else {
                    self.log("측정 실패: \(errorText ?? "알 수 없는 오류")")
                }
            }
        }
    }

    func copyLog() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
        log("기록을 클립보드에 복사했어요")
    }

    func clearLog() {
        lines = []
        UserDefaults.standard.removeObject(forKey: Self.logKey)
        log("기록을 지웠어요. 앱 서명: \(codeSigningSummary())")
    }

    private func makeProxy() -> HelperProtocol? {
        let connection = self.connection ?? makeConnection()
        self.connection = connection
        let proxy = connection.remoteObjectProxyWithErrorHandler { [weak self] error in
            let text = describe(error)
            Task { @MainActor in
                self?.log("XPC 오류: \(text)")
                self?.dropConnection()
            }
        }
        guard let helper = proxy as? HelperProtocol else {
            log("보조 프로그램 연결을 만들지 못했어요")
            return nil
        }
        return helper
    }

    private func makeConnection() -> NSXPCConnection {
        // .privileged: 시스템 영역(LaunchDaemon)에 있는 서비스에 연결해요.
        let connection = NSXPCConnection(machServiceName: HelperConstants.label, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: HelperProtocol.self)
        // 같은 팀이 서명한 보조 프로그램에만 말을 걸어요.
        connection.setCodeSigningRequirement(HelperConstants.teamRequirement)
        connection.invalidationHandler = { [weak self] in
            Task { @MainActor in
                self?.log("XPC 연결이 끊겼어요")
                self?.connection = nil
            }
        }
        connection.resume()
        return connection
    }

    private func dropConnection() {
        connection?.invalidate()
        connection = nil
    }

    private func log(_ text: String) {
        let time = Date().formatted(date: .omitted, time: .standard)
        lines.append("[\(time)] \(text)")
        UserDefaults.standard.set(lines, forKey: Self.logKey)
    }
}

/// 오류를 도메인·코드와 함께 한 줄로 보여줘요. 시스템이 붙여 준 자세한 설명이 있으면 같이 적어요.
func describe(_ error: Error) -> String {
    let nsError = error as NSError
    var text = "\(nsError.localizedDescription) [\(nsError.domain) \(nsError.code)]"
    if let detail = nsError.userInfo[NSDebugDescriptionErrorKey] as? String {
        text += " 자세히: \(detail)"
    }
    if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
        text += " 원인: [\(underlying.domain) \(underlying.code)]"
    }
    return text
}

/// 이 앱 프로세스의 코드 서명 상태(커널이 관리하는 CS 플래그)를 읽어요.
/// Xcode 디버거가 중단점을 넣으려고 코드를 고치면 커널이 VALID 표시를 지워요.
/// 그러면 보조 프로그램 쪽 서명 확인에서 연결이 거절될 수 있어서, 비교하려고 기록에 남겨요.
func codeSigningSummary() -> String {
    // int csops(pid_t pid, unsigned int ops, void *useraddr, size_t usersize)
    typealias CSOpsFunction = @convention(c) (pid_t, UInt32, UnsafeMutableRawPointer?, Int) -> Int32
    // RTLD_DEFAULT((void *)-2): 이미 불러온 모든 라이브러리에서 찾아요.
    guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "csops") else {
        return "확인 불가 (csops 없음)"
    }
    let csops = unsafeBitCast(symbol, to: CSOpsFunction.self)
    var flags: UInt32 = 0
    // 0 = CS_OPS_STATUS
    guard csops(getpid(), 0, &flags, MemoryLayout<UInt32>.size) == 0 else {
        return "확인 불가 (errno \(errno))"
    }
    let valid = flags & 0x0000_0001 != 0      // CS_VALID
    let debugged = flags & 0x1000_0000 != 0   // CS_DEBUGGED
    return "유효(VALID) \(valid ? "예" : "아니오") · 디버거 흔적(DEBUGGED) \(debugged ? "예" : "아니오") [0x\(String(flags, radix: 16))]"
}
