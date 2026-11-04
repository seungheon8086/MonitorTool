// 1단계 부하: 쉼 → 쓰기 → 순차 읽기 → 무작위 읽기(동시 1·8) → 쉼.
// 단계가 바뀔 때마다 시각과 드라이버 통계를 남긴다. 시험 파일은 결과 폴더에 만들고 끝나면 지운다.
import Foundation

let MiB = 1 << 20

/// 종료 신호(Ctrl-C 등)를 받으면 1. 신호 처리기에서 쓴다.
var stopRequested: Int32 = 0

private func stopping() -> Bool { stopRequested != 0 }

struct PhaseMark {
    let name: String
    let time: UInt64                    // ns, 추적 이벤트와 같은 기준
    let stats: [UInt64: DriverStats]    // 그 순간의 드라이버 통계
}

final class PhaseLog {
    private let lock = NSLock()
    private var marks: [PhaseMark] = []
    private var finished = false

    func mark(_ name: String, _ map: DiskMap) {
        let time = Timebase.now()
        let stats = map.allStats()
        lock.lock()
        marks.append(PhaseMark(name: name, time: time, stats: stats))
        lock.unlock()
    }

    func finish() {
        lock.lock()
        finished = true
        lock.unlock()
    }

    var isFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return finished
    }

    var all: [PhaseMark] {
        lock.lock()
        defer { lock.unlock() }
        return marks
    }
}

private func rest(_ seconds: Double) {
    let end = Timebase.now() + UInt64(seconds * 1e9)
    while Timebase.now() < end && !stopping() { usleep(50_000) }
}

/// 1 MiB씩 캐시 없이 쓰고 마지막에 F_FULLFSYNC (디스크 캐시 비우기 명령이 나감)
private func writeFile(_ path: String, mib: Int) -> String {
    let fd = open(path, O_CREAT | O_RDWR | O_TRUNC, 0o644)
    guard fd >= 0 else { return "열기 실패 (errno \(errno))" }
    defer { close(fd) }
    _ = fcntl(fd, F_NOCACHE, 1)
    let buf = UnsafeMutableRawPointer.allocate(byteCount: MiB, alignment: 16384)
    defer { buf.deallocate() }
    arc4random_buf(buf, MiB)
    var written = 0
    while written < mib && !stopping() {
        buf.storeBytes(of: UInt64(written), as: UInt64.self)
        let n = pwrite(fd, buf, MiB, off_t(written) * off_t(MiB))
        if n != MiB { return "쓰기 실패 (errno \(errno))" }
        written += 1
    }
    _ = fcntl(fd, F_FULLFSYNC)
    return "\(written) MiB"
}

/// 처음부터 끝까지 1 MiB씩 캐시 없이 읽기를 passes번
private func readFile(_ path: String, passes: Int) -> String {
    let fd = open(path, O_RDONLY)
    guard fd >= 0 else { return "열기 실패 (errno \(errno))" }
    defer { close(fd) }
    _ = fcntl(fd, F_NOCACHE, 1)
    let buf = UnsafeMutableRawPointer.allocate(byteCount: MiB, alignment: 16384)
    defer { buf.deallocate() }
    var total = 0
    for _ in 0..<passes {
        var offset: off_t = 0
        while !stopping() {
            let n = pread(fd, buf, MiB, offset)
            if n <= 0 { break }
            total += n
            offset += off_t(n)
        }
    }
    return "\(total / MiB) MiB"
}

private final class Counter {
    private let lock = NSLock()
    private(set) var ops = 0

    func add(_ n: Int) {
        lock.lock()
        ops += n
        lock.unlock()
    }
}

/// 4 KiB 무작위 읽기를 스레드 threads개로 seconds초 (스레드마다 한 번에 하나씩)
private func randomRead(_ path: String, seconds: Double, threads: Int) -> String {
    var st = stat()
    guard stat(path, &st) == 0 else { return "파일 없음" }
    let blocks = UInt32(min(UInt64(st.st_size) / 4096, UInt64(UInt32.max)))
    guard blocks > 0 else { return "파일이 너무 작음" }
    let counter = Counter()
    let group = DispatchGroup()
    let end = Timebase.now() + UInt64(seconds * 1e9)
    for _ in 0..<threads {
        group.enter()
        Thread {
            defer { group.leave() }
            let fd = open(path, O_RDONLY)
            guard fd >= 0 else { return }
            defer { close(fd) }
            _ = fcntl(fd, F_NOCACHE, 1)
            let buf = UnsafeMutableRawPointer.allocate(byteCount: 4096, alignment: 16384)
            defer { buf.deallocate() }
            var ops = 0
            while Timebase.now() < end && !stopping() {
                let offset = off_t(arc4random_uniform(blocks)) * 4096
                if pread(fd, buf, 4096, offset) <= 0 { break }
                ops += 1
            }
            counter.add(ops)
        }.start()
    }
    group.wait()
    return "\(counter.ops)번"
}

/// 쉼 5초 → 쓰기 512 MiB → 순차 읽기 2번(1 GiB) → 무작위 4 KiB 동시 1 · 3초 → 동시 8 · 2초 → 쉼 3초
func runCheckLoad(directory: String, map: DiskMap, log: PhaseLog, note: @escaping (String) -> Void) {
    let path = directory + "/load.bin"
    log.mark("쉼", map)
    rest(5)
    note("쉼 5초")
    if !stopping() {
        log.mark("쓰기 1MiB", map)
        note("쓰기 " + writeFile(path, mib: 512))
    }
    if !stopping() {
        log.mark("순차 읽기 1MiB", map)
        note("순차 읽기 " + readFile(path, passes: 2))
    }
    if !stopping() {
        log.mark("무작위 4KiB 동시 1", map)
        note("무작위 4 KiB 동시 1 · " + randomRead(path, seconds: 3, threads: 1))
    }
    if !stopping() {
        log.mark("무작위 4KiB 동시 8", map)
        note("무작위 4 KiB 동시 8 · " + randomRead(path, seconds: 2, threads: 8))
    }
    if !stopping() {
        log.mark("쉼 (끝)", map)
        rest(3)
        note("쉼 3초")
    }
    log.mark("끝", map)
    unlink(path)
    log.finish()
}
