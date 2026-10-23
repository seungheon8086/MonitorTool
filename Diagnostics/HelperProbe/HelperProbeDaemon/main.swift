// 관리자 권한 보조 프로그램 (LaunchDaemon)
//
// 앱이 SMAppService로 등록하고 사용자가 시스템 설정에서 허용하면, launchd가 root 권한으로 실행해요.
// XPC로 같은 팀이 서명한 HelperProbe 앱의 요청만 받고, 정해진 일(권한 확인, powermetrics 1회 실행)만 해요.

import Foundation

/// 보조 프로그램이 실제로 하는 일이에요.
final class HelperService: NSObject, HelperProtocol {
    func identity(reply: @escaping (String) -> Void) {
        reply("uid \(getuid()), euid \(geteuid()), pid \(getpid())")
    }

    func samplePower(reply: @escaping ([String: NSNumber]?, String?) -> Void) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/powermetrics")
        // 인자는 여기서 고정해요. 앱이 다른 인자나 다른 명령을 보낼 방법은 없어요.
        process.arguments = ["--samplers", "cpu_power,gpu_power,ane_power", "-i", "1000", "-n", "1", "-f", "plist"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            reply(nil, "powermetrics를 실행하지 못했어요: \(error.localizedDescription)")
            return
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            reply(nil, "powermetrics 종료 코드 \(process.terminationStatus)")
            return
        }

        // plist 형식은 표본마다 NUL 문자로 끝나요.
        let firstSample = data.split(separator: 0).first ?? data
        guard let plist = try? PropertyListSerialization.propertyList(from: firstSample, format: nil) as? [String: Any],
              let processor = plist["processor"] as? [String: Any] else {
            reply(nil, "powermetrics 출력을 해석하지 못했어요 (\(data.count)바이트)")
            return
        }

        var values: [String: NSNumber] = [:]
        for key in ["cpu_power", "gpu_power", "ane_power", "combined_power"] {
            if let value = processor[key] as? NSNumber {
                values[key] = value
            }
        }
        if let elapsed = plist["elapsed_ns"] as? NSNumber {
            values["elapsed_ns"] = elapsed
        }
        reply(values, nil)
    }
}

/// 새 XPC 연결이 오면 HelperService를 붙여 줘요.
final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: HelperProtocol.self)
        connection.exportedObject = HelperService()
        connection.resume()
        NSLog("HelperProbeDaemon: 연결 받음 (pid %d)", connection.processIdentifier)
        return true
    }
}

NSLog("HelperProbeDaemon: 시작 (uid %d)", getuid())

let listener = NSXPCListener(machServiceName: HelperConstants.label)
// 같은 팀이 서명한 HelperProbe 앱의 연결만 받아요. 요구사항에 맞지 않는 연결은 시스템이 끊어요.
listener.setConnectionCodeSigningRequirement(HelperConstants.appRequirement)
let delegate = ListenerDelegate()
listener.delegate = delegate
listener.resume()

dispatchMain()
