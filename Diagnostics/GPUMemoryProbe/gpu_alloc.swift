// GPU 메모리를 정해진 크기만큼 할당했다가 놓으면서, IORegistry의 'Alloc system memory'와
// 'In use system memory'가 정확히 그만큼 움직이는지 확인해요. (Windows 작업 관리자의 GPU 메모리처럼
// '할당량'인지 확인하는 시험) Metal이 알려 주는 GPU 권장 최대치도 함께 적어요.
//
// 빌드와 실행:
//   swiftc -O gpu_alloc.swift -o gpu_alloc && ./gpu_alloc

import Foundation
import IOKit
import Metal

struct GPUStats {
    var alloc: Double?   // 바이트
    var inUse: Double?
}

func readStats() -> GPUStats {
    let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOAccelerator"))
    guard service != 0 else { return GPUStats() }
    defer { IOObjectRelease(service) }
    guard let stats = IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString,
                                                      kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any] else {
        return GPUStats()
    }
    return GPUStats(alloc: (stats["Alloc system memory"] as? NSNumber)?.doubleValue,
                    inUse: (stats["In use system memory"] as? NSNumber)?.doubleValue)
}

func gb(_ bytes: Double?) -> String {
    guard let bytes else { return "읽지 못함" }
    return String(format: "%.3f GB", bytes / 1_000_000_000)
}

func gib(_ bytes: UInt64) -> String { String(format: "%.2f GiB", Double(bytes) / 1_073_741_824) }

guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
    print("⚠️ Metal 장치를 열지 못했어요."); exit(1)
}
print("GPU: \(device.name), 통합 메모리: \(device.hasUnifiedMemory)")
print("권장 최대치(recommendedMaxWorkingSetSize): \(gib(device.recommendedMaxWorkingSetSize)) = \(gb(Double(device.recommendedMaxWorkingSetSize)))")
print("한 버퍼 최대(maxBufferLength): \(gib(UInt64(device.maxBufferLength)))")
print()

/// 2초 기다렸다가 1초 간격 3번 읽은 평균
func measure() -> GPUStats {
    Thread.sleep(forTimeInterval: 2)
    var allocs: [Double] = [], inUses: [Double] = []
    for index in 0..<3 {
        let s = readStats()
        if let a = s.alloc { allocs.append(a) }
        if let u = s.inUse { inUses.append(u) }
        if index < 2 { Thread.sleep(forTimeInterval: 1) }
    }
    func avg(_ v: [Double]) -> Double? { v.isEmpty ? nil : v.reduce(0, +) / Double(v.count) }
    return GPUStats(alloc: avg(allocs), inUse: avg(inUses))
}

var base = GPUStats()
func report(_ label: String, expected: Double) {
    let s = measure()
    if label == "시작" { base = s }
    let delta = (s.alloc != nil && base.alloc != nil) ? s.alloc! - base.alloc! : nil
    let deltaText = delta.map { String(format: "%+.3f GB", $0 / 1_000_000_000) } ?? "-"
    print("\(label) | 기대 증가 \(String(format: "%.3f GB", expected / 1_000_000_000)) | Alloc \(gb(s.alloc)) (시작 대비 \(deltaText)) | In use \(gb(s.inUse)) | 이 프로그램 currentAllocatedSize \(gb(Double(device.currentAllocatedSize)))")
}

let oneGB = 1 << 30   // 1 GiB = 1.074 GB

report("시작", expected: 0)

// 1) CPU·GPU가 함께 쓰는 버퍼 1 GiB, CPU에서 모두 써서 실제 메모리를 차지하게 해요.
var shared: MTLBuffer? = device.makeBuffer(length: oneGB, options: .storageModeShared)
if let shared { memset(shared.contents(), 1, oneGB) } else { print("⚠️ 공유 버퍼를 만들지 못했어요.") }
report("공유 1 GiB", expected: Double(oneGB))

// 2) GPU 전용 버퍼 1 GiB 추가, GPU로 채워서 실제로 쓰게 해요.
var gpuOnly: MTLBuffer? = device.makeBuffer(length: oneGB, options: .storageModePrivate)
if let gpuOnly, let commands = queue.makeCommandBuffer(), let blit = commands.makeBlitCommandEncoder() {
    blit.fill(buffer: gpuOnly, range: 0..<oneGB, value: 7)
    blit.endEncoding()
    commands.commit()
    commands.waitUntilCompleted()
} else { print("⚠️ GPU 전용 버퍼를 만들지 못했어요.") }
report("공유 + GPU 전용 2 GiB", expected: Double(2 * oneGB))

// 3) 하나씩 놓기
gpuOnly = nil
report("GPU 전용 놓음", expected: Double(oneGB))
shared = nil
report("모두 놓음", expected: 0)
print()
print("완료")
