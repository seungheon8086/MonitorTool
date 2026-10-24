import Darwin
import Foundation

/// host_statistics64로 읽은 메모리 페이지 중 화면에 쓰는 것을 바이트로 바꾼 값이에요.
nonisolated struct MemoryPages: Hashable, Sendable {
    /// 비어 있는 메모리
    var free: Double
    /// 파일 내용을 담은 페이지 (external). 메모리가 모자라면 바로 비울 수 있어요.
    var fileBacked: Double
    /// 압축한 내용이 실제로 차지하는 메모리 (활성 상태 보기의 '압축됨')
    var compressed: Double

    /// 활성 상태 보기의 '사용된 메모리'와 같은 값이에요: 전체 − 빈 메모리 − 파일 페이지.
    /// (2026-10-25 같은 때 비교해 12.89 GB로 같았어요. '앱 메모리 + 와이어드 + 압축됨'은 이보다 0.9 GB쯤 작아서 쓰지 않아요)
    func used(total: Double) -> Double {
        min(max(total - free - fileBacked, 0), total)
    }
}

/// 메모리 통계를 읽어요. 모두 관리자 권한 없이 읽혀요.
nonisolated enum MemoryReader {
    /// mach_host_self()는 부를 때마다 포트 참조가 늘어서 한 번만 받아 둬요.
    private static let host = mach_host_self()

    /// 페이지 크기 (바이트). Apple Silicon은 16 KB예요.
    static func pageSize() -> Double? {
        var size: vm_size_t = 0
        guard host_page_size(host, &size) == KERN_SUCCESS, size > 0 else {
            return nil
        }
        return Double(size)
    }

    /// 페이지 종류별 양. 읽지 못하면 nil이에요.
    static func pages(pageSize: Double) -> MemoryPages? {
        var statistics = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &statistics) { (pointer: UnsafeMutablePointer<vm_statistics64>) -> kern_return_t in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { (raw: UnsafeMutablePointer<integer_t>) -> kern_return_t in
                host_statistics64(host, HOST_VM_INFO64, raw, &count)
            }
        }
        guard result == KERN_SUCCESS else {
            return nil
        }
        return MemoryPages(free: Double(statistics.free_count) * pageSize,
                           fileBacked: Double(statistics.external_page_count) * pageSize,
                           compressed: Double(statistics.compressor_page_count) * pageSize)
    }

    /// 설치된 메모리 (바이트)
    static func physicalMemory() -> Double? {
        var value: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        guard sysctlbyname("hw.memsize", &value, &size, nil, 0) == 0, value > 0 else {
            return nil
        }
        return Double(value)
    }

    /// 쓰고 있는 스왑 (바이트)
    static func swapUsed() -> Double? {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else {
            return nil
        }
        return Double(usage.xsu_used)
    }

    /// 시스템이 판단한 메모리 압력이에요. (kern.memorystatus_vm_pressure_level: 1 정상, 2 주의, 4 높음)
    /// 사용률로 색을 정하지 않고 이 값을 그대로 써요. (설계 문서 3장)
    static func pressure() -> MemoryPressure? {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else {
            return nil
        }
        switch level {
        case 1:
            return .normal
        case 2:
            return .warning
        case 4:
            return .critical
        default:
            return nil
        }
    }
}

/// 메모리 사용량·전체·압력·압축·스왑을 재요. (DRAM 트래픽은 IOReportCollector가 채워요)
final class MemoryCollector {
    /// 설치된 메모리는 바뀌지 않아서 한 번만 읽어요.
    private let total: Double?
    private let pageSize: Double?

    init() {
        total = MemoryReader.physicalMemory()
        pageSize = MemoryReader.pageSize()
    }

    func update(_ memory: inout MemorySnapshot, now: Date) {
        let pages = pageSize.flatMap { MemoryReader.pages(pageSize: $0) }

        if let total {
            memory.total = .ok(total, at: now)
        } else {
            memory.total = .failed("설치된 메모리 크기를 읽지 못했어요.")
        }

        if let total, let pages {
            memory.used = .ok(pages.used(total: total), at: now)
        } else {
            memory.used = .failed("메모리 통계를 읽지 못했어요.")
        }

        if let pages {
            memory.compressed = .ok(pages.compressed, at: now)
        } else {
            memory.compressed = .failed("메모리 통계를 읽지 못했어요.")
        }

        if let swap = MemoryReader.swapUsed() {
            memory.swapUsed = .ok(swap, at: now)
        } else {
            memory.swapUsed = .failed("스왑 사용량을 읽지 못했어요.")
        }

        if let pressure = MemoryReader.pressure() {
            memory.pressure = .ok(pressure, at: now)
        } else {
            memory.pressure = .failed("메모리 압력을 읽지 못했어요.")
        }
    }
}
