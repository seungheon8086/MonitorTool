// DiskProbe: 디스크 I/O 통계(IOBlockStorageDriver의 "Statistics")를 관리자 권한 없이 읽어 보는 진단 도구
// 명령: list | sample <초> <파일> <간격> | idle <초> | write <파일> <초> <파일MiB> <최대MiB>
//       | read <파일> <초> | randread <파일> <초> <스레드> <블록KiB>
import Foundation
import IOKit

setvbuf(stdout, nil, _IOLBF, 0)

let MiB = 1 << 20

func uptimeNs() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }
func monoNs() -> UInt64 { clock_gettime_nsec_np(CLOCK_MONOTONIC) }
func now() -> Double { Double(uptimeNs()) / 1e9 }
func wall() -> String { String(format: "%.3f", Date().timeIntervalSince1970) }

struct Disk {
    let service: io_registry_entry_t
    let bsd: String
    let info: [(String, String)]
}

func search(_ s: io_registry_entry_t, _ key: String, parents: Bool) -> Any? {
    var opts = IOOptionBits(kIORegistryIterateRecursively)
    if parents { opts |= IOOptionBits(kIORegistryIterateParents) }
    return IORegistryEntrySearchCFProperty(s, kIOServicePlane, key as CFString, kCFAllocatorDefault, opts)
}

func findDisks() -> [Disk] {
    var it: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &it) == KERN_SUCCESS else { return [] }
    defer { IOObjectRelease(it) }
    var out: [Disk] = []
    while true {
        let s = IOIteratorNext(it)
        if s == 0 { break }
        let bsd = (search(s, "BSD Name", parents: false) as? String) ?? "?"
        var info: [(String, String)] = []
        for key in ["Protocol Characteristics", "Device Characteristics"] {
            if let d = search(s, key, parents: true) as? [String: Any] {
                for k in d.keys.sorted() where !k.contains("Serial") && !k.contains("Path") { info.append(("\(key) > \(k)", "\(d[k]!)")) }
            }
        }
        for key in ["NVMe SMART Capable", "SMART Capable"] {
            if let v = search(s, key, parents: true) { info.append((key, "\(v)")) }
        }
        var chain: [String] = []
        var cur = s
        IOObjectRetain(cur)
        for _ in 0..<10 {
            if let c = IOObjectCopyClass(cur)?.takeRetainedValue() { chain.append(c as String) }
            var p: io_registry_entry_t = 0
            let r = IORegistryEntryGetParentEntry(cur, kIOServicePlane, &p)
            IOObjectRelease(cur)
            cur = 0
            if r != KERN_SUCCESS { break }
            cur = p
        }
        if cur != 0 { IOObjectRelease(cur) }
        info.append(("부모", chain.joined(separator: " < ")))
        out.append(Disk(service: s, bsd: bsd, info: info))
    }
    return out
}

func statistics(_ s: io_registry_entry_t) -> [(String, UInt64)]? {
    guard let d = IORegistryEntryCreateCFProperty(s, "Statistics" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any] else { return nil }
    return d.keys.sorted().compactMap { k in (d[k] as? NSNumber).map { (k, $0.uint64Value) } }
}

func list() {
    let disks = findDisks()
    print("IOBlockStorageDriver \(disks.count)개")
    for d in disks {
        print("\n== \(d.bsd)")
        for (k, v) in d.info { print("  \(k): \(v)") }
        let t0 = uptimeNs()
        let st = statistics(d.service)
        let t1 = uptimeNs()
        if let st {
            for (k, v) in st { print("  Statistics > \(k): \(v)") }
        } else {
            print("  Statistics: 없음")
        }
        print(String(format: "  읽는 데 걸린 시간: %.1f µs", Double(t1 - t0) / 1000))
    }
}

func sample(seconds: Double, path: String, interval: Double) {
    FileManager.default.createFile(atPath: path, contents: nil)
    guard let fh = FileHandle(forWritingAtPath: path) else { fputs("파일을 열 수 없음: \(path)\n", stderr); exit(1) }
    fh.write("wall\tuptime_ns\tmonotonic_ns\tdisk\tkey\tvalue\n".data(using: .utf8)!)
    var disks = findDisks()
    var lastScan = uptimeNs()
    let start = Date()
    var n = 0
    while Date().timeIntervalSince(start) < seconds {
        if uptimeNs() - lastScan > 5_000_000_000 {
            for d in disks { IOObjectRelease(d.service) }
            disks = findDisks()
            lastScan = uptimeNs()
        }
        var lines = ""
        let w = wall()
        let t0 = uptimeNs()
        let m = monoNs()
        for d in disks {
            if let st = statistics(d.service) {
                for (k, v) in st { lines += "\(w)\t\(t0)\t\(m)\t\(d.bsd)\t\(k)\t\(v)\n" }
            }
        }
        let t1 = uptimeNs()
        lines += "\(w)\t\(t0)\t\(m)\t_\t_read_ns\t\(t1 - t0)\n"
        fh.write(lines.data(using: .utf8)!)
        n += 1
        let wait = start.addingTimeInterval(Double(n) * interval).timeIntervalSinceNow
        if wait > 0 { Thread.sleep(forTimeInterval: wait) }
    }
}

func report(_ s: String, _ e: String, _ bytes: UInt64, _ ops: UInt64) {
    print("\(s)\t\(e)\t\(bytes)\t\(ops)")
}

func fileSize(_ fd: Int32) -> UInt64 {
    var st = stat()
    fstat(fd, &st)
    return UInt64(st.st_size)
}

func loadWrite(path: String, seconds: Double, fileMiB: Int, maxMiB: Int) {
    let fd = open(path, O_CREAT | O_RDWR, 0o644)
    guard fd >= 0 else { perror("open"); exit(1) }
    _ = fcntl(fd, F_NOCACHE, 1)
    let buf = UnsafeMutableRawPointer.allocate(byteCount: MiB, alignment: 16384)
    arc4random_buf(buf, MiB)
    let limit = UInt64(fileMiB) * UInt64(MiB)
    let cap = UInt64(maxMiB) * UInt64(MiB)
    var off: UInt64 = 0
    var bytes: UInt64 = 0
    var ops: UInt64 = 0
    let s = wall()
    let t = now()
    while now() - t < seconds && bytes < cap {
        buf.storeBytes(of: bytes, as: UInt64.self)
        let n = pwrite(fd, buf, MiB, off_t(off))
        if n <= 0 { perror("pwrite"); break }
        bytes += UInt64(n)
        ops += 1
        off += UInt64(n)
        if off >= limit { off = 0 }
    }
    _ = fcntl(fd, F_FULLFSYNC)
    let e = wall()
    close(fd)
    buf.deallocate()
    report(s, e, bytes, ops)
}

func loadRead(path: String, seconds: Double) {
    let fd = open(path, O_RDONLY)
    guard fd >= 0 else { perror("open"); exit(1) }
    _ = fcntl(fd, F_NOCACHE, 1)
    let size = fileSize(fd)
    guard size >= UInt64(MiB) else { fputs("파일이 너무 작음\n", stderr); exit(1) }
    let buf = UnsafeMutableRawPointer.allocate(byteCount: MiB, alignment: 16384)
    var off: UInt64 = 0
    var bytes: UInt64 = 0
    var ops: UInt64 = 0
    let s = wall()
    let t = now()
    while now() - t < seconds {
        let n = pread(fd, buf, MiB, off_t(off))
        if n < 0 { perror("pread"); break }
        if n == 0 { off = 0; continue }
        bytes += UInt64(n)
        ops += 1
        off += UInt64(n)
        if off + UInt64(MiB) > size { off = 0 }
    }
    let e = wall()
    close(fd)
    buf.deallocate()
    report(s, e, bytes, ops)
}

final class Counter {
    let lock = NSLock()
    var bytes: UInt64 = 0
    var ops: UInt64 = 0
    func add(_ b: UInt64, _ o: UInt64) { lock.lock(); bytes += b; ops += o; lock.unlock() }
}

func loadRandRead(path: String, seconds: Double, threads: Int, blockKiB: Int) {
    let block = blockKiB * 1024
    let pfd = open(path, O_RDONLY)
    guard pfd >= 0 else { perror("open"); exit(1) }
    let size = fileSize(pfd)
    close(pfd)
    let blocks = UInt32(min(size / UInt64(block), UInt64(UInt32.max)))
    guard blocks > 0 else { fputs("파일이 너무 작음\n", stderr); exit(1) }
    let counter = Counter()
    let group = DispatchGroup()
    let s = wall()
    let t = now()
    for _ in 0..<threads {
        group.enter()
        Thread {
            let fd = open(path, O_RDONLY)
            if fd >= 0 {
                _ = fcntl(fd, F_NOCACHE, 1)
                let buf = UnsafeMutableRawPointer.allocate(byteCount: block, alignment: 16384)
                var b: UInt64 = 0
                var o: UInt64 = 0
                while now() - t < seconds {
                    let off = off_t(arc4random_uniform(blocks)) * off_t(block)
                    let n = pread(fd, buf, block, off)
                    if n <= 0 { break }
                    b += UInt64(n)
                    o += 1
                }
                buf.deallocate()
                close(fd)
                counter.add(b, o)
            }
            group.leave()
        }.start()
    }
    group.wait()
    report(s, wall(), counter.bytes, counter.ops)
}

let args = CommandLine.arguments
func arg(_ i: Int) -> String { i < args.count ? args[i] : "" }

switch arg(1) {
case "list":
    list()
case "sample":
    sample(seconds: Double(arg(2)) ?? 300, path: arg(3), interval: Double(arg(4)) ?? 1)
case "idle":
    let s = wall()
    Thread.sleep(forTimeInterval: Double(arg(2)) ?? 10)
    report(s, wall(), 0, 0)
case "write":
    loadWrite(path: arg(2), seconds: Double(arg(3)) ?? 15, fileMiB: Int(arg(4)) ?? 4096, maxMiB: Int(arg(5)) ?? 8192)
case "read":
    loadRead(path: arg(2), seconds: Double(arg(3)) ?? 15)
case "randread":
    loadRandRead(path: arg(2), seconds: Double(arg(3)) ?? 15, threads: Int(arg(4)) ?? 1, blockKiB: Int(arg(5)) ?? 4)
default:
    print("사용법: diskprobe list | sample <초> <파일> <간격> | idle <초> | write <파일> <초> <파일MiB> <최대MiB> | read <파일> <초> | randread <파일> <초> <스레드> <블록KiB>")
    exit(2)
}
