// 4단계: 비용·오래 켜 두기. 읽는 방식(간격·버퍼 기준치 대기), 부하를 내는 따로 된 프로세스(work), 메모리 재기.
// 시험은 cost.sh(비용 시험)와 soak(밤새 켜 두기, Holder에 soak 설정)이 한다.
import Foundation

/// 이벤트를 읽는 방식
enum ReadMode {
    case every(UInt64)      // 정한 간격마다 (ns)
    case wait               // KDBUFWAIT: 버퍼가 절반 차거나 다음 1초 경계가 될 때까지 커널 안에서 기다렸다가

    /// "100"(ms, 10~5000) 또는 "w"
    static func parse(_ text: String) -> ReadMode? {
        if text == "w" { return .wait }
        guard let ms = UInt64(text), ms >= 10, ms <= 5000 else { return nil }
        return .every(ms * 1_000_000)
    }

    var text: String {
        switch self {
        case .every(let ns): return "\(ns / 1_000_000) ms마다"
        case .wait: return "버퍼 기준치 대기(절반 또는 1초 경계)"
        }
    }

    /// 표에 쓰는 짧은 이름
    var key: String {
        switch self {
        case .every(let ns): return "\(ns / 1_000_000)"
        case .wait: return "w"
        }
    }
}

/// 이 프로세스의 메모리 (활성 상태 보기의 '메모리'와 같은 phys_footprint, 바이트)
func memoryFootprint() -> UInt64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { raw in
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), raw, &count)
        }
    }
    return kr == KERN_SUCCESS ? UInt64(info.phys_footprint) : 0
}

/// 모든 프로세스의 시스템 콜(BSD + Mach)·페이지 폴트·문맥 전환이 늘어난 양 (proc_pidinfo PROC_PIDTASKINFO, root라 모두 읽힘).
/// 추적이 켜져 있으면 이런 추적 지점마다 걸러 내는 일이 생기므로(비용 시험: 시스템 콜 한 번에 약 11 ns),
/// soak에서 1분마다 재서 다른 프로그램이 받는 비용을 어림한다. 프로세스마다 32비트 누적이라 넘침을 감안해 빼고,
/// 그 1분 사이에 끝난 프로세스의 몫은 빠진다(조금 적게 나옴)
final class SystemCounters {
    struct Delta {
        var syscalls: UInt64 = 0
        var faults: UInt64 = 0
        var switches: UInt64 = 0
        var processes = 0
    }

    private struct Counts {
        var unix: UInt32
        var mach: UInt32
        var faults: UInt32
        var switches: UInt32
    }

    private var last: [Int32: Counts] = [:]
    private(set) var sampleCPU: UInt64 = 0
    private(set) var samples = 0

    /// 지난번부터 늘어난 양. 처음 부르면 기준만 잡고 0을 돌려준다
    func sample() -> Delta {
        let c0 = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        defer {
            sampleCPU += clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - c0
            samples += 1
        }
        var out = Delta()
        let estimate = Int(proc_listallpids(nil, 0))
        guard estimate > 0 else { return out }
        var pids = [Int32](repeating: 0, count: estimate + 64)
        let found = pids.withUnsafeMutableBytes { raw -> Int32 in
            proc_listallpids(raw.baseAddress, Int32(raw.count))
        }
        guard found > 0 else { return out }
        let first = last.isEmpty
        var now: [Int32: Counts] = [:]
        now.reserveCapacity(Int(found))
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        for pid in pids.prefix(min(Int(found), pids.count)) where pid > 0 {
            var info = proc_taskinfo()
            guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size else { continue }
            let c = Counts(unix: UInt32(bitPattern: info.pti_syscalls_unix), mach: UInt32(bitPattern: info.pti_syscalls_mach),
                           faults: UInt32(bitPattern: info.pti_faults), switches: UInt32(bitPattern: info.pti_csw))
            now[pid] = c
            if first { continue }
            let p = last[pid] ?? Counts(unix: 0, mach: 0, faults: 0, switches: 0)
            out.syscalls += UInt64(c.unix &- p.unix) + UInt64(c.mach &- p.mach)
            out.faults += UInt64(c.faults &- p.faults)
            out.switches += UInt64(c.switches &- p.switches)
        }
        out.processes = now.count
        last = now
        return out
    }
}

/// 시스템 콜 한 번의 평균 시간. getppid()는 진짜 시스템 콜이다(libc가 값을 저장해 두지 않음).
/// 커널 추적이 켜져 있으면(tailspin이든 우리든) 시스템 콜·인터럽트마다 추적 지점이 형식 필터를 거치므로,
/// 평소와 우리가 쥔 동안을 번갈아 재서 시스템 쪽 비용을 본다. 효율 코어로 가지 않게 QoS를 사용자 상호작용으로 올린다
func syscallCost(until: UInt64) -> String {
    _ = pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0)
    let t0 = Timebase.now()
    let c0 = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
    var n: UInt64 = 0
    while Timebase.now() < until && stopRequested == 0 {
        for _ in 0..<10_000 { _ = getppid() }
        n += 10_000
    }
    let cpu = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - c0
    let wall = minus(Timebase.now(), t0)
    guard n > 0 else { return "시스템 콜 0번" }
    return String(format: "시스템 콜 한 번 %.1f ns (CPU) · %.1f ns (벽시계)", Double(cpu) / Double(n), Double(wall) / Double(n))
        + " · \(comma(n))번"
}

/// work <파일> prepare <MiB> <초> | work <파일> randread <스레드> <초> | work - syscall 0 <초>
/// 추적을 쥔 프로세스와 따로 부하를 낸다 (부하 스레드의 CPU가 추적 비용에 섞이지 않게)
func runWork(path: String, kind: String, amount: Int, seconds: Int) -> Int32 {
    installSignalHandlers()
    let until = Timebase.now() + UInt64(max(seconds, 1)) * 1_000_000_000
    switch kind {
    case "prepare":
        print("쓰기 " + writeSequential(path, fileMiB: amount, capMiB: amount, until: until))
    case "randread":
        print("4 KiB 무작위 읽기 동시 \(amount) · " + readRandom(path, threads: amount, until: until))
    case "syscall":
        print(syscallCost(until: until))
    default:
        print("사용법: work <파일> prepare <MiB> <초> | work <파일> randread <스레드> <초> | work - syscall 0 <초>")
        return 2
    }
    return 0
}
