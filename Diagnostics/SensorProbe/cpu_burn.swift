// CPU에 일정 시간 계산 부하를 주는 도구예요. 온도 센서가 E코어·P코어 중 어디에 반응하는지 보려고 써요.
//
// QoS가 background인 스레드는 E코어에서만 돌고, userInteractive 스레드는 P코어를 먼저 써요.
//
// 빌드와 실행:
//   swiftc -O cpu_burn.swift -o cpu_burn
//   ./cpu_burn 25 background 4   # 25초 동안 E코어에 스레드 4개
//   ./cpu_burn 25 user 8         # 25초 동안 P코어 위주로 스레드 8개

import Foundation

func log(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

let arguments = CommandLine.arguments
let seconds = arguments.count > 1 ? (Double(arguments[1]) ?? 20) : 20
let qosName = arguments.count > 2 ? arguments[2] : "user"
let threadCount = arguments.count > 3 ? max(Int(arguments[3]) ?? 4, 1) : 4

let qos: QualityOfService
switch qosName {
case "background": qos = .background
case "utility": qos = .utility
default: qos = .userInteractive
}

log("CPU 부하: \(Int(seconds))초, QoS \(qosName), 스레드 \(threadCount)개")

let deadline = Date().addingTimeInterval(seconds)
let group = DispatchGroup()
for index in 0..<threadCount {
    group.enter()
    let thread = Thread {
        var x = Double(index) + 1.5
        var rounds = 0
        while Date() < deadline {
            for _ in 0..<200_000 {
                x = x * 1.000_001 + 0.000_001
                if x > 1_000_000 { x = 1.5 }
            }
            rounds += 1
        }
        // 계산 결과를 쓰는 척해서 컴파일러가 반복을 없애지 못하게 해요.
        if x == 42.424_242 {
            log("우연히 같은 값")
        }
        log("스레드 \(index): \(rounds)회 반복")
        group.leave()
    }
    thread.qualityOfService = qos
    thread.start()
}
group.wait()
log("완료")
