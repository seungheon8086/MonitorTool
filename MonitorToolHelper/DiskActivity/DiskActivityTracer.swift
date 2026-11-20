// 디스크 활성 시간 추적 서비스 (docs/DISK_ACTIVE_TIME.md 3.3 · 4.1)
// 앱이 묻는 동안 커널 추적(kdebug)을 쥐고, 1초 경계마다 물리 디스크별 누적값을 만들어 마지막 것만 둔다.
// 규칙은 Diagnostics/DiskActiveProbe의 hold(Stage3.swift Holder)에서 옮겼다. 도구만 하던 일(1초 표본 쓰기·보고서·
// 드라이버 통계·추정·CPU 나눠 보기)은 뺐다. 추정과 대조는 앱이 드라이버 통계로 한다.
//
// - 잡기: 잡기 직전에 프로세스 목록을 한 번 보고 추적 도구가 돌고 있으면 기다린다. 다른 도구가 쥐고 있으면 손대지 않고 2초마다 다시
// - 읽기: 버퍼 기준치 대기(w). 커널 안에서 기다리다 버퍼의 절반이 차면 바로, 아니면 1초 경계 30 ms 뒤에 읽는다
// - 1초마다: 소유자가 나인지 본다. 밀려났으면 남의 설정은 건드리지 않고 2초마다 다시 잡아 본다
// - 비켜주기: 추적 도구의 실행 이벤트를 보면 바로 놓고, 그 도구가 끝나고 10초 뒤에 다시 잡는다
// - 디스크 목록: 30초마다 구성 표식만 보고 바뀌었을 때만 다시 만든다. 모르는 장치가 보이면 2초 뒤
// - 잠자기: 깬 뒤 커널 기록이 꺼져 있으면 내려놓고 다시 잡는다 (도구 시험에서는 한 번도 없었음)
// - 놓기: 앱이 묻지 않은 지 max(간격 × 3, 15초) · 놓기 요청(설정에서 끔) · 앱 연결이 모두 끊김 · 보조 프로그램이 끝날 때
//
// 스레드: 추적 스레드 하나가 잡기·읽기·처리를 한다. 커널 추적을 만지는 일은 traceLock 안에서만 하고,
// 커널 안에서 기다리는 동안(KERN_KDBUFWAIT, 최대 약 1초)은 잠금을 풀어 두어 다른 스레드가 바로 놓을 수 있다.
import Darwin
import Foundation
import os

/// 디스크 추적 기록. `log show`에서 내용이 보이게 공개로 남긴다 (2026-11-06 사용자 결정, 다른 기록은 HelperLog로 2026-11-21부터 같은 방식).
/// 보기: log show --last 30m --style compact --predicate 'subsystem == "com.seungheon.MonitorTool.helper"'
private let diskLog = Logger(subsystem: HelperConstants.label, category: "diskActivity")

/// 지금 추적을 쥐고 있는지 (충돌 신호 처리기가 읽는다. 힙을 쓰지 않으려고 전역 정수)
nonisolated(unsafe) var diskTraceHeld: Int32 = 0

final class DiskActivityTracer: @unchecked Sendable {
    private enum Phase {
        case idle           // 스레드 없음
        case running        // 앱이 묻는 동안
        case stopping       // 놓고 스레드를 끝내는 중
        case shutDown       // 보조 프로그램이 끝나는 중 (다시 잡지 않음)
    }

    // MARK: 앱 요청과 나누는 상태 (lock 안에서만)
    private let lock = NSLock()
    private var phase = Phase.idle
    /// 끝내는 중에 요청이 다시 왔음 (스레드가 끝나는 대신 다시 돈다)
    private var restartWanted = false
    private var latestSample = DiskActivitySample.without(.off)
    private var latestProblem: String?
    /// 마지막 요청 시각 (CLOCK_UPTIME_RAW, ns). 잠든 시간은 빠져서 깨어난 뒤 바로 놓지 않는다
    private var lastRequestAt: UInt64 = 0
    private var intervalMilliseconds = HelperConstants.panelOpenInterval

    // MARK: 커널 추적 (traceLock 안에서만)
    private let traceLock = NSLock()
    private var holding = false

    // MARK: 추적 스레드만 쓰는 것
    private var engine: Engine?
    private var map: DiskMap?
    private var physical: [PhysicalDisk] = []
    private var mapSignature: [UInt64] = []
    private var mapCheckedAt: UInt64 = 0
    private var generation: UInt64 = 0
    private var nextTry: UInt64 = 0
    private var nextRead: UInt64 = 0
    private var yieldedTo: String?
    private var yieldedPids: Set<Int32> = []
    private var lastToolSeen: UInt64 = 0
    private var lastTickWall = Date()
    private var lastTickMono: UInt64 = 0
    private var lastWake: UInt64 = 0
    private var busyCount = 0

    /// 추적 도구가 끝나고 다시 잡기까지 (도구 3단계 결정 10초)
    private static let grace: UInt64 = 10_000_000_000
    /// 버퍼 크기 요청. 작게 요청하면 커널이 최솟값으로 올린다 (이 Mac은 368,640개 = 22.5 MiB)
    private static let bufferEvents: Int32 = 262_144

    // MARK: - 앱 요청 (XPC 스레드)

    /// 가장 최근 누적값과 문제 글을 돌려준다. 쥐고 있지 않으면 추적 스레드를 띄운다 (첫 답은 '꺼짐'이나 '준비 중')
    func latest(intervalMilliseconds requested: Int) -> (sample: DiskActivitySample, problem: String?) {
        // 정해 둔 간격만 받아요. 다른 값이 오면 1초로 해요. (전력과 같은 규칙)
        let interval = HelperConstants.sampleIntervals.contains(requested)
            ? requested : HelperConstants.panelOpenInterval
        lock.lock()
        defer { lock.unlock() }
        lastRequestAt = DiskActivityTracer.uptime()
        intervalMilliseconds = interval
        switch phase {
        case .idle:
            phase = .running
            let thread = Thread { [self] in run() }
            thread.name = "MonitorToolHelper.diskActivity"
            thread.start()
        case .stopping:
            restartWanted = true
        case .running, .shutDown:
            break
        }
        return (latestSample, latestProblem)
    }

    /// 바로 놓는다 (설정에서 끔 · 앱 연결이 모두 끊김). 다음 요청이 오면 다시 잡는다
    func release(reason: String) {
        lock.lock()
        if phase == .running { phase = .stopping }
        restartWanted = false
        lock.unlock()
        releaseNow(reason: reason)
    }

    /// 보조 프로그램이 끝날 때 (SIGTERM · 연결 없음 · 실행 파일 교체): 놓고 다시 잡지 않는다
    func shutdown() {
        lock.lock()
        phase = .shutDown
        restartWanted = false
        lock.unlock()
        releaseNow(reason: "보조 프로그램 끝남")
    }

    /// 다른 스레드에서 놓기. 추적 스레드가 읽거나 처리하는 중이면 끝날 때까지 기다린다(길어야 수 ms).
    /// 추적 스레드가 커널 안에서 기다리는 중이면 잠금이 풀려 있어 바로 놓는다 (docs/DISK_ACTIVE_TIME.md 3.3-10)
    private func releaseNow(reason: String) {
        if traceLock.lock(before: Date().addingTimeInterval(2)) {
            if holding {
                let problem = releaseTrace()
                holding = false
                diskTraceHeld = 0
                let note = problem.map { " · 해제 문제: \($0)" } ?? ""
                diskLog.notice("디스크 추적 놓음 (\(reason, privacy: .public))\(note, privacy: .public)")
            }
            traceLock.unlock()
        } else {
            // 추적 스레드가 2초 넘게 잠금을 쥐고 있어요(멈춤). 내가 소유자일 때만 커널 추적을 놓아요.
            let problem = releaseTraceIfMine()
            diskTraceHeld = 0
            let note = problem.map { " · 해제 문제: \($0)" } ?? ""
            diskLog.error("디스크 추적 놓음 (\(reason, privacy: .public), 추적 스레드 응답 없음)\(note, privacy: .public)")
        }
    }

    /// 보조 프로그램이 뜰 때: 소유자 없이 남은 추적(강제 종료로 남은 것)이 있으면 끄고 해제한다. 설정이 꺼져 있어도 한다
    static func cleanUpLeftovers() {
        guard let info = try? Kdebug.info(), info.ownerPid <= 0, info.flags & KD.flagBufInit != 0 else { return }
        try? Kdebug.enable(false)
        try? Kdebug.remove()
        diskLog.notice("소유자 없이 남은 커널 추적을 정리함")
    }

    private static func uptime() -> UInt64 {
        clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
    }

    // MARK: - 추적 스레드

    private func run() {
        while true {
            loop()
            // 아직 소유자로 남아 있으면 놓는다 (밖에서 놓은 바로 그 순간에 커널 대기를 불러 다시 소유자가 된 경우 등)
            traceLock.lock()
            if holding {
                _ = releaseTrace()
                holding = false
                diskTraceHeld = 0
                diskLog.notice("디스크 추적 놓음 (앱이 묻지 않음)")
            } else {
                _ = releaseTraceIfMine()
            }
            traceLock.unlock()
            engine = nil
            map = nil
            lock.lock()
            if phase == .stopping && restartWanted {
                restartWanted = false
                phase = .running
                lock.unlock()
                continue
            }
            if phase != .shutDown { phase = .idle }
            latestSample = .without(.off)
            latestProblem = nil
            lock.unlock()
            return
        }
    }

    /// 앱이 아직 묻고 있는지. 묻지 않은 지 max(간격 × 3, 15초)가 지났으면 끝내기로 바꾼다
    private func stillWanted() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if phase == .running {
            let limit = max(UInt64(intervalMilliseconds) * 3_000_000, 15_000_000_000)
            if minus(DiskActivityTracer.uptime(), lastRequestAt) > limit { phase = .stopping }
        }
        return phase == .running
    }

    private func loop() {
        let start = Timebase.now()
        engine = nil
        let m = DiskMap()
        map = m
        physical = m.physical
        mapSignature = DiskMap.signature()
        mapCheckedAt = start
        yieldedTo = nil
        yieldedPids = []
        nextTry = 0
        busyCount = 0
        lastTickWall = Date()
        lastTickMono = start
        var k: UInt64 = 0
        var nextTick = start
        var early = false
        tryAcquire(now: start)
        nextRead = Timebase.now()
        while stillWanted() {
            var now = Timebase.now()
            if now >= nextTick {
                tick(at: now)
                k += 1
                nextTick = start + k * 1_000_000_000
                if nextTick <= now {
                    // 많이 늦었으면 (스레드가 오래 밀림) 지난 경계를 몰아서 세지 않고 다음 경계로
                    k = (now - start) / 1_000_000_000 + 1
                    nextTick = start + k * 1_000_000_000
                }
            }
            if engine != nil {
                if early || now >= nextRead {
                    early = false
                    readAndProcess()
                    now = Timebase.now()
                    nextRead = nextTick + 30_000_000
                }
            } else if now >= nextTry {
                tryAcquire(now: now)
                nextRead = Timebase.now()
            }
            refreshMapIfNeeded(Timebase.now())
            let target = min(nextTick, engine != nil ? nextRead : max(nextTry, Timebase.now()))
            early = pause(until: target)
        }
    }

    /// 아직 쥐고 있는지 (밖에서 놓았으면 엔진을 버린다)
    private func stillHolding() -> Bool {
        traceLock.lock()
        let held = holding
        traceLock.unlock()
        if !held { engine = nil }
        return held
    }

    /// 1초 경계: 잠자기 뒤 점검, 경계 시각 넣기, 소유자 확인
    private func tick(at now: UInt64) {
        let wallNow = Date()
        // 벽시계는 잠든 동안에도 가지만 mach_absolute_time은 멈춘다
        let gap = wallNow.timeIntervalSince(lastTickWall) - Double(minus(now, lastTickMono)) / 1e9
        lastTickWall = wallNow
        lastTickMono = now
        guard let e = engine, stillHolding() else { return }
        if gap > 5, let info = try? Kdebug.info(), info.recordingOff {
            lose(reason: "깬 뒤 커널 기록이 꺼져 있음")
            return
        }
        e.addTick(now)
        // 다른 root 프로세스가 kperf로 소유자를 바꿨는지 (blessed_preempt)
        if let owner = sysctlInt32("ktrace.owning_pid"), owner != getpid() {
            lose(reason: "소유자가 바뀜")
        }
    }

    private func readAndProcess() {
        guard let e = engine else { return }
        traceLock.lock()
        guard holding else {
            traceLock.unlock()
            engine = nil
            return
        }
        do {
            try e.read()
        } catch {
            traceLock.unlock()
            lose(reason: "읽기 실패 (\(error))")
            return
        }
        let tools = e.takeExecs().filter { traceToolNames.contains($0.name) && $0.pid != getpid() }
        if let tool = tools.first {
            yieldLocked(to: tool.name, pid: tool.pid, seenAt: tool.time)
            traceLock.unlock()
            return
        }
        traceLock.unlock()
        let produced = e.process(until: minus(Timebase.now(), 20_000_000))
        if let last = produced.last {
            publish(e, boundary: last.time, totals: last.totals)
        }
    }

    /// 추적 도구의 실행을 봤다: 바로 놓고 그 도구가 끝나기를 기다린다. traceLock 안에서 부른다
    private func yieldLocked(to name: String, pid: Int32, seenAt: UInt64) {
        let problem = releaseTrace()
        holding = false
        diskTraceHeld = 0
        engine = nil
        yieldedTo = name
        if pid > 0 { yieldedPids.insert(pid) }
        lastToolSeen = Timebase.now()
        nextTry = lastToolSeen + 1_000_000_000
        setState(.otherTool, otherTool: name)
        let lag = Double(minus(lastToolSeen, seenAt)) / 1e6
        let note = problem.map { " · 해제 문제: \($0)" } ?? ""
        diskLog.notice("디스크 추적 비켜줌 · \(name, privacy: .public)(\(pid, privacy: .public)) · 실행부터 \(lag, format: .fixed(precision: 0), privacy: .public) ms\(note, privacy: .public)")
    }

    /// 밀려났거나 읽지 못함: 내가 아직 소유자면 내 설정만 놓고, 2초 뒤 다시 잡아 본다
    private func lose(reason: String) {
        engine = nil
        traceLock.lock()
        let s = KtraceState.read()
        var cleanup = ""
        if holding {
            holding = false
            diskTraceHeld = 0
            if s.owningPid == getpid() {
                cleanup = releaseTrace().map { " · 내 쪽 해제 문제: \($0)" } ?? " · 내 쪽 남은 설정 해제"
            }
        }
        traceLock.unlock()
        let other = s.owningPid > 0 && s.owningPid != getpid() ? ownerName(s.owningPid, s) : nil
        if let other {
            setState(.otherTool, otherTool: other)
        } else {
            setState(.failed, problem: "디스크 추적 \(reason)")
        }
        nextTry = Timebase.now() + 2_000_000_000
        let owner = ownerName(s.owningPid, s)
        diskLog.notice("디스크 추적 밀려남 · \(reason, privacy: .public) · 지금 \(s.stateName, privacy: .public) · 소유 \(owner, privacy: .public)\(cleanup, privacy: .public)")
    }

    private func tryAcquire(now: UInt64) {
        // 비켜준 도구가 아직 살아 있으면 기다린다 (pid만 보므로 싸다)
        yieldedPids = yieldedPids.filter { processAlive($0) }
        if !yieldedPids.isEmpty {
            lastToolSeen = now
            nextTry = now + 1_000_000_000
            return
        }
        if yieldedTo != nil && minus(now, lastToolSeen) < DiskActivityTracer.grace {
            nextTry = lastToolSeen + DiskActivityTracer.grace
            return
        }
        // 잡기 직전에 한 번: 비켜준 동안 켜진 도구, 먼저 켜 둔 도구 (Instruments 등)
        let tools = runningProcesses(named: traceToolNames)
        if let first = tools.first {
            for t in tools { yieldedPids.insert(t.pid) }
            yieldedTo = first.name
            lastToolSeen = now
            nextTry = now + 1_000_000_000
            setState(.otherTool, otherTool: first.name)
            return
        }
        traceLock.lock()
        // 잠금을 쥔 채로 한 번 더: 그사이 놓기 요청이 왔으면 잡지 않는다
        lock.lock()
        let wanted = phase == .running
        lock.unlock()
        guard wanted else {
            traceLock.unlock()
            return
        }
        let result = acquireTrace(events: DiskActivityTracer.bufferEvents, filter: {
            try Kdebug.setTypeFilter(Engine.kinds(ssd: true))
        })
        if case .acquired = result {
            holding = true
            diskTraceHeld = 1
        }
        traceLock.unlock()
        switch result {
        case .acquired(let cleaned):
            guard let m = map else { return }
            let e = Engine(map: m, ssdEvents: true)
            e.watchExecs = true
            engine = e
            generation = Timebase.now()
            let after = yieldedTo.map { " · \($0)이(가) 끝나고 \(minus(now, lastToolSeen) / 1_000_000_000)초 뒤" } ?? ""
            yieldedTo = nil
            busyCount = 0
            setState(.starting)
            let note = cleaned ? " · 소유자 없이 남은 추적을 먼저 정리함" : ""
            diskLog.notice("디스크 추적 잡음\(note, privacy: .public)\(after, privacy: .public)")
        case .busy(let owner):
            busyCount += 1
            if busyCount == 1 || busyCount % 30 == 0 {
                diskLog.notice("디스크 추적 못 잡음 · \(owner, privacy: .public) 사용 중 · 2초마다 다시 (\(self.busyCount, privacy: .public)번째)")
            }
            nextTry = now + 2_000_000_000
            setState(.otherTool, otherTool: owner)
        case .failed(let text):
            nextTry = now + 5_000_000_000
            setState(.failed, problem: "디스크 추적 \(text)")
            diskLog.error("디스크 추적 못 잡음 · \(text, privacy: .public) · 5초 뒤 다시")
        }
    }

    /// target까지 쉰다. 쥐고 있으면 커널 안에서 기다리다 버퍼가 절반 차면 일찍 깬다 (참이면 바로 읽기)
    private func pause(until target: UInt64) -> Bool {
        let now = Timebase.now()
        guard target > now else { return false }
        if engine != nil, stillHolding() {
            let left = target - now
            do {
                let exceeded = try Kdebug.waitForBuffer(timeoutMs: Int(min(left / 1_000_000 + 1, 1000)))
                if exceeded {
                    // 다 읽었는데도 곧바로 또 기준치면(커널이 단위를 늦게 돌려주는 등) 20 ms 쉬고 읽는다. 헛도는 것을 막는다
                    if minus(Timebase.now(), lastWake) < 20_000_000 { usleep(20_000) }
                    lastWake = Timebase.now()
                    return true
                }
                if minus(Timebase.now(), now) + 5_000_000 >= left { return false }
                // 기준치도 시간도 아닌데 돌아옴 (신호 등) → 남은 시간은 그냥 잔다
            } catch {
                // 밖에서 놓은 직후 등. 남은 시간은 그냥 잔다
            }
        }
        let rest = minus(target, Timebase.now()) / 1000
        if rest > 0 { usleep(useconds_t(min(rest, 999_999))) }
        return false
    }

    /// 디스크 목록: 30초마다 구성 표식만 싸게 보고, 바뀌었을 때만 다시 만들어 엔진과 같이 쓴다.
    /// 엔진이 모르는 장치를 봤으면(꽂은 디스크) 2초 뒤에 바로 본다
    private func refreshMapIfNeeded(_ now: UInt64) {
        let unknownSeen = engine?.wantsNewMap(at: now) ?? false
        guard unknownSeen || minus(now, mapCheckedAt) > 30_000_000_000 else { return }
        mapCheckedAt = now
        let signature = DiskMap.signature()
        guard signature != mapSignature else {
            engine?.acknowledgeUnknown()        // 구성이 그대로면 다시 만들어도 모르는 장치는 그대로다
            return
        }
        let m = DiskMap()
        map = m
        physical = m.physical
        mapSignature = signature
        engine?.useMap(m)
    }

    // MARK: - 답 만들기

    private func publish(_ e: Engine, boundary: UInt64, totals: [UInt64: DiskTotals]) {
        let disks = physical.map { d -> DiskActivityDisk in
            let t = totals[d.id] ?? DiskTotals()
            return DiskActivityDisk(id: d.id, activeNs: t.active, operations: t.ops, bytes: t.bytes)
        }
        let sample = DiskActivitySample(state: .tracing, otherTool: nil, generation: generation, boundary: boundary,
                                        disks: disks, lostEvents: e.losses, flushTrim: e.flushTrimSeen)
        lock.lock()
        latestSample = sample
        latestProblem = nil
        lock.unlock()
    }

    private func setState(_ state: DiskActivityState, otherTool: String? = nil, problem: String? = nil) {
        let sample = DiskActivitySample.without(state, otherTool: otherTool,
                                                generation: state == .starting ? generation : 0)
        lock.lock()
        latestSample = sample
        latestProblem = problem
        lock.unlock()
    }
}

// MARK: - 충돌 때 놓기

/// 커널 추적을 끄고 해제한다. 충돌 신호 처리기에서 부르므로 힙을 쓰지 않는다 (KERN_KDEBUG 24 > KDENABLE 3 · KDREMOVE 7)
func emergencyRelease() {
    var mib: (Int32, Int32, Int32, Int32) = (CTL_KERN, 24, 3, 0)
    var length = 0
    withUnsafeMutablePointer(to: &mib) { tuple in
        tuple.withMemoryRebound(to: Int32.self, capacity: 4) { m in
            _ = sysctl(m, 4, nil, &length, nil, 0)
            m[2] = 7
            _ = sysctl(m, 3, nil, &length, nil, 0)
        }
    }
}

/// 보조 프로그램이 뜰 때 한 번: 충돌(배열 범위 밖 등)로 끝나도 추적이 켜진 채 남지 않게 한다.
/// 놓은 뒤 신호를 기본 동작으로 다시 보내서 충돌 보고서는 그대로 남는다
func installCrashRelease() {
    _ = diskTraceHeld   // 신호 처리기보다 먼저 초기화
    for s in [SIGTRAP, SIGSEGV, SIGBUS, SIGILL, SIGABRT, SIGFPE] {
        signal(s) { sig in
            if diskTraceHeld != 0 { emergencyRelease() }
            signal(sig, SIG_DFL)
            raise(sig)
        }
    }
}
