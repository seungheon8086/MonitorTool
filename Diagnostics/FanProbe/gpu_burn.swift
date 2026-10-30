// GPU를 꽉 채우는 계산 부하 도구예요. Metal 계산 셰이더로 곱셈·덧셈을 끝없이 반복해요.
// Vision 이미지 분류(ane_load gpu)는 GPU를 다 쓰지 못해서, 팬 시험용으로 따로 만들었어요.
//
// 빌드와 실행:
//   swiftc -O gpu_burn.swift -o gpu_burn
//   ./gpu_burn 60        # 60초 동안 GPU 최대 부하

import Foundation
import Metal

func log(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

let seconds = CommandLine.arguments.count > 1 ? (Double(CommandLine.arguments[1]) ?? 60) : 60

let source = """
#include <metal_stdlib>
using namespace metal;

kernel void burn(device float4 *out [[buffer(0)]],
                 uint id [[thread_position_in_grid]]) {
    float4 a = float4(id) * 1e-6 + float4(0.1, 0.2, 0.3, 0.4);
    float4 b = float4(1.0001, 0.9999, 1.0002, 0.9998);
    float4 c = float4(1e-7);
    for (uint i = 0; i < 4096; i++) {
        a = fma(a, b, c);
        b = fma(b, a, c) * 0.5 + 0.5;
    }
    out[id] = a + b;
}
"""

guard let device = MTLCreateSystemDefaultDevice() else {
    log("Metal 장치를 찾지 못했어요.")
    exit(1)
}
guard let queue = device.makeCommandQueue() else {
    log("명령 큐를 만들지 못했어요.")
    exit(1)
}

let pipeline: MTLComputePipelineState
do {
    let library = try device.makeLibrary(source: source, options: nil)
    guard let function = library.makeFunction(name: "burn") else {
        log("셰이더 함수를 찾지 못했어요.")
        exit(1)
    }
    pipeline = try device.makeComputePipelineState(function: function)
} catch {
    log("셰이더를 만들지 못했어요: \(error)")
    exit(1)
}

let threadCount = 1 << 20
guard let buffer = device.makeBuffer(length: threadCount * MemoryLayout<SIMD4<Float>>.stride,
                                     options: .storageModePrivate) else {
    log("버퍼를 만들지 못했어요.")
    exit(1)
}

print("GPU 부하: \(device.name), \(Int(seconds))초")
fflush(stdout)

let width = min(pipeline.maxTotalThreadsPerThreadgroup, 256)
let end = Date().addingTimeInterval(seconds)
var batches = 0
var lastReport = Date()
// 명령 버퍼를 2개씩 겹쳐 보내서 GPU가 쉬는 틈이 없게 해요.
var inFlight: [MTLCommandBuffer] = []
while Date() < end {
    guard let commands = queue.makeCommandBuffer(),
          let encoder = commands.makeComputeCommandEncoder() else {
        log("명령 버퍼를 만들지 못했어요.")
        exit(1)
    }
    encoder.setComputePipelineState(pipeline)
    encoder.setBuffer(buffer, offset: 0, index: 0)
    encoder.dispatchThreads(MTLSize(width: threadCount, height: 1, depth: 1),
                            threadsPerThreadgroup: MTLSize(width: width, height: 1, depth: 1))
    encoder.endEncoding()
    commands.commit()
    inFlight.append(commands)
    if inFlight.count >= 2 {
        inFlight.removeFirst().waitUntilCompleted()
    }
    batches += 1
    if Date().timeIntervalSince(lastReport) >= 30 {
        print("\(batches)회")
        fflush(stdout)
        lastReport = Date()
    }
}
inFlight.forEach { $0.waitUntilCompleted() }
print("끝: \(batches)회")
