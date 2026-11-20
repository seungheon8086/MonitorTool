import Foundation

/// powermetrics를 계속 실행하면서 가장 최근 전력 표본을 들고 있어요.
/// 요청마다 새로 실행하면 1초 표본에 준비 시간 0.8초가 더 붙어서(Diagnostics/HelperProbe),
/// 앱이 묻는 동안은 계속 돌리고, 한동안 묻지 않으면 멈춰요.
/// 상태는 모두 queue 안에서만 읽고 바꿔요.
final class PowerSampler: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.seungheon.MonitorTool.helper.power")

    private var process: Process?
    /// 지금 돌고 있는 powermetrics의 번호예요. 멈춘 프로세스가 늦게 보낸 출력과 종료 알림은 버려요.
    private var generation = 0
    private var intervalMilliseconds = HelperConstants.panelOpenInterval
    /// 아직 끝까지 오지 않은 표본 조각
    private var buffer = Data()
    private var latest: PowerSample?
    private var problem: String?
    private var lastRequestAt = Date.distantPast
    private var lastStartAt = Date.distantPast
    private var idleTimer: DispatchSourceTimer?
    /// 전력 값을 찾지 못한 표본이 연달아 나온 수. 세 번 이어질 때만 문제로 알려요.
    private var unreadableCount = 0

    /// 표본 하나의 끝 표시 (powermetrics는 표본마다 plist 문서 하나를 내보내요)
    private static let endMarker = Data("</plist>".utf8)

    /// 가장 최근 표본과 문제 설명을 돌려줘요. 필요하면 powermetrics를 켜거나 간격을 바꿔요.
    func latest(intervalMilliseconds requested: Int) -> (sample: PowerSample?, problem: String?) {
        queue.sync { () -> (sample: PowerSample?, problem: String?) in
            // 정해 둔 간격만 받아요. 다른 값이 오면 1초로 해요.
            let interval = HelperConstants.sampleIntervals.contains(requested)
                ? requested : HelperConstants.panelOpenInterval
            lastRequestAt = Date()
            if process == nil || interval != intervalMilliseconds {
                start(intervalMilliseconds: interval)
            }
            startIdleTimerIfNeeded()
            return (latest, problem)
        }
    }

    /// powermetrics를 멈춰요. (보조 프로그램이 끝날 때)
    func stop() {
        queue.sync {
            stopProcess()
        }
    }

    // MARK: - powermetrics 실행 (queue 안에서만 불러요)

    private func start(intervalMilliseconds interval: Int) {
        // 방금 실패했다면 5초 동안은 다시 켜지 않아요. 계속 실패할 때 쉬지 않고 다시 켜는 것을 막아요.
        if process == nil, problem != nil, Date().timeIntervalSince(lastStartAt) < 5 {
            return
        }
        stopProcess()
        generation += 1
        let generation = self.generation

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/powermetrics")
        // 인자는 여기서만 정해요. 앱이 다른 인자나 다른 명령을 보낼 방법은 없어요.
        // -b 1: 줄마다 바로 내보내요. (파이프로 받으면 출력이 모였다가 늦게 나올 수 있어서요)
        // -a 0: 표본 10개마다 끼워 넣는 평균 요약을 꺼요. 표본만 받아요.
        // (두 옵션 모두 이 Mac의 powermetrics 도움말에 있어요: Diagnostics/PowerProbe/results/help.txt)
        // GPU 전력은 앱이 IOReport로 직접 읽어서 여기서는 재지 않아요. (2026-11-04 자원 사용 측정 뒤 뺌)
        process.arguments = ["--samplers", "cpu_power,ane_power",
                             "-i", String(interval), "-f", "plist", "-b", "1", "-a", "0"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                // 출력이 끝났어요. (프로세스가 끝남)
                handle.readabilityHandler = nil
                return
            }
            guard let self else { return }
            self.queue.async {
                self.receive(data, generation: generation)
            }
        }
        process.terminationHandler = { [weak self] finished in
            let status = finished.terminationStatus
            guard let self else { return }
            self.queue.async {
                self.ended(generation: generation, status: status)
            }
        }

        lastStartAt = Date()
        do {
            try process.run()
        } catch {
            problem = "powermetrics를 실행하지 못했어요. (\(error.localizedDescription))"
            return
        }
        self.process = process
        intervalMilliseconds = interval
        buffer.removeAll()
        unreadableCount = 0
        NSLog("MonitorToolHelper: powermetrics 시작 (%ld ms 간격)", interval)
    }

    private func stopProcess() {
        guard let process else { return }
        self.process = nil
        // 번호를 바꿔서, 멈춘 프로세스의 남은 출력과 종료 알림을 무시해요.
        generation += 1
        (process.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        if process.isRunning {
            process.terminate()
        }
        buffer.removeAll()
        NSLog("MonitorToolHelper: powermetrics 멈춤")
    }

    private func ended(generation: Int, status: Int32) {
        // 일부러 멈춘 프로세스면 번호가 달라서 여기서 끝나요.
        guard generation == self.generation else { return }
        process = nil
        buffer.removeAll()
        problem = "powermetrics가 멈췄어요. (종료 코드 \(status))"
        NSLog("MonitorToolHelper: powermetrics가 스스로 끝남 (종료 코드 %d)", status)
    }

    // MARK: - 출력 읽기

    private func receive(_ data: Data, generation: Int) {
        guard generation == self.generation else { return }
        // 새로 들어온 부분(과 앞 조각에 걸친 몇 바이트)에서만 표본의 끝을 찾아요.
        var searchStart = max(buffer.startIndex, buffer.endIndex - (Self.endMarker.count - 1))
        buffer.append(data)
        while let end = buffer.range(of: Self.endMarker, in: searchStart..<buffer.endIndex) {
            let sample = buffer.subdata(in: buffer.startIndex..<end.upperBound)
            buffer.removeSubrange(buffer.startIndex..<end.upperBound)
            parse(sample)
            searchStart = buffer.startIndex
        }
        // 끝 표시 없이 계속 쌓이면 출력 형식이 바뀐 거예요. 버리고 알려요.
        if buffer.count > 2_000_000 {
            buffer.removeAll()
            problem = "powermetrics 출력 형식이 예상과 달라요."
        }
    }

    private func parse(_ chunk: Data) {
        // 표본 사이의 NUL 문자와 줄바꿈을 떼고 '<?xml'부터 읽어요.
        guard let start = chunk.firstIndex(of: UInt8(ascii: "<")) else { return }
        let xml = chunk.subdata(in: start..<chunk.endIndex)
        guard let plist = (try? PropertyListSerialization.propertyList(from: xml, format: nil)) as? [String: Any],
              let processor = plist["processor"] as? [String: Any] else {
            // 전력 값이 없는 문서가 가끔 섞일 수 있어서 한두 번은 넘겨요. 이어지면 알려요.
            unreadableCount += 1
            if unreadableCount >= 3 {
                problem = "powermetrics 출력을 읽지 못했어요."
            }
            return
        }
        unreadableCount = 0

        let expected = Double(intervalMilliseconds) / 1000
        let elapsed = (plist["elapsed_ns"] as? NSNumber).map { $0.doubleValue / 1_000_000_000 }
        if let elapsed, elapsed > expected * 1.5 + 0.5 {
            // 잠자기 등으로 표본 구간이 너무 길어졌어요. 그 평균은 지금 값이 아니라서 버려요.
            return
        }

        func milliwatts(_ key: String) -> Double? {
            (processor[key] as? NSNumber)?.doubleValue
        }
        latest = PowerSample(cpuMilliwatts: milliwatts("cpu_power"),
                             aneMilliwatts: milliwatts("ane_power"),
                             interval: elapsed ?? expected,
                             measuredAt: Date())
        problem = nil
    }

    // MARK: - 한동안 묻지 않으면 멈추기

    private func startIdleTimerIfNeeded() {
        guard idleTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in
            self?.stopIfIdle()
        }
        timer.resume()
        idleTimer = timer
    }

    /// 앱이 간격의 3배(적어도 15초) 동안 묻지 않으면 powermetrics를 멈춰요.
    private func stopIfIdle() {
        let limit = max(Double(intervalMilliseconds) / 1000 * 3, 15)
        guard Date().timeIntervalSince(lastRequestAt) > limit else { return }
        stopProcess()
        latest = nil
        problem = nil
        idleTimer?.cancel()
        idleTimer = nil
    }
}
