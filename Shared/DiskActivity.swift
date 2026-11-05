import Foundation

// 디스크 활성 시간에서 앱과 관리자 권한 보조 프로그램이 함께 쓰는 값이에요. (docs/DISK_ACTIVE_TIME.md 3.1)
// 보조 프로그램은 %를 내지 않고 물리 디스크별 누적값과 그 기준 시각(1초 경계)만 넘겨요.
// 앱이 받을 때마다 앞에 받은 것과의 차이로 %를 내요. JSON으로 XPC를 지나가요.

/// 보조 프로그램의 디스크 추적 상태예요.
nonisolated enum DiskActivityState: String, Codable, Hashable, Sendable {
    /// 추적 중. boundary·disks는 이 회차의 마지막 1초 경계 값이에요.
    case tracing
    /// 잡았지만 아직 1초 경계가 없어요.
    case starting
    /// 다른 추적 도구가 쓰는 중이에요. (비켜줬거나 그 도구가 먼저 쥐고 있어요)
    case otherTool
    /// 쥐고 있지 않아요.
    case off
    /// 잡기·읽기에 실패했어요. (까닭은 답의 두 번째 값)
    case failed
}

/// 물리 디스크 하나의 누적값이에요.
nonisolated struct DiskActivityDisk: Codable, Hashable, Sendable {
    /// IOBlockStorageDriver의 IORegistry 항목 ID (앱의 DiskDevice.id와 같아요)
    var id: UInt64
    /// 활성 누적 (ns). 내장 SSD는 디스크 I/O ∪ 캐시 비우기 ∪ TRIM, 다른 디스크는 디스크 I/O
    var activeNs: UInt64
    /// 끝까지 본 디스크 I/O 작업 수와 바이트 (앱이 드라이버 통계의 읽기+쓰기와 대조해요)
    var operations: UInt64
    var bytes: UInt64
}

/// 보조 프로그램이 주는 디스크 활성 시간 누적값이에요.
nonisolated struct DiskActivitySample: Codable, Hashable, Sendable {
    var state: DiskActivityState
    /// 다른 추적 도구 이름 (알면, 예: "xctrace")
    var otherTool: String?
    /// 회차: 추적을 잡은 시각 (ns, mach_absolute_time). 누적값은 같은 회차 안에서만 이어져요.
    var generation: UInt64
    /// 누적값의 기준 시각 (ns, mach_absolute_time = 앱의 CLOCK_UPTIME_RAW. 잠든 시간은 빠져요)
    var boundary: UInt64
    /// 그 회차의 디스크 목록에 있는 물리 디스크 모두 (요청이 없었으면 0)
    var disks: [DiskActivityDisk]
    /// 이 회차에서 커널 버퍼가 넘친 횟수 (TRACE_LOST_EVENTS)
    var lostEvents: UInt64
    /// 내장 SSD의 캐시 비우기·TRIM 이벤트를 받는지 (거짓이면 디스크 I/O만)
    var flushTrim: Bool

    /// 누적값이 없는 답 (추적 중이 아닐 때)
    static func without(_ state: DiskActivityState, otherTool: String? = nil, generation: UInt64 = 0) -> DiskActivitySample {
        DiskActivitySample(state: state, otherTool: otherTool, generation: generation, boundary: 0,
                           disks: [], lostEvents: 0, flushTrim: false)
    }
}
