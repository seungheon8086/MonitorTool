// ANE(Neural Engine)·GPU·CPU 중 지정한 장치에서만 Vision 이미지 분류를 반복해서,
// powermetrics의 전력·활성 비율 값이 그 장치에서 실제로 반응하는지 확인하는 부하 생성기예요.
//
// 빌드와 실행:
//   swiftc -O ane_load.swift -o ane_load
//   ./ane_load 30 ane     # 30초 동안 ANE에서 실행 (gpu, cpu도 가능)

import CoreGraphics
import CoreML
import Foundation
import Vision

enum Target: String {
    case ane, gpu, cpu

    func matches(_ device: MLComputeDevice) -> Bool {
        switch (self, device) {
        case (.ane, .neuralEngine), (.gpu, .gpu), (.cpu, .cpu):
            return true
        default:
            return false
        }
    }
}

/// 진행 상황은 표준 오류로 바로 써요. (파일로 저장할 때 버퍼에 묶여 사라지지 않도록)
func log(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

func describe(_ device: MLComputeDevice) -> String {
    switch device {
    case .cpu: return "CPU"
    case .gpu: return "GPU"
    case .neuralEngine: return "ANE"
    @unknown default: return String(describing: device)
    }
}

/// 모델이 매번 실제로 계산하도록 무늬가 다른 테스트 이미지를 만들어요.
func makeImage(seed: Int) -> CGImage {
    let size = 512
    guard let context = CGContext(data: nil, width: size, height: size,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        fatalError("이미지를 만들 수 없어요")
    }
    for index in 0..<24 {
        let red = CGFloat((index * 37 + seed * 11) % 256) / 255
        let green = CGFloat((index * 59 + seed * 17) % 256) / 255
        let blue = CGFloat((index * 83 + seed * 29) % 256) / 255
        context.setFillColor(CGColor(red: red, green: green, blue: blue, alpha: 1))
        let x = CGFloat((index * 53 + seed * 7) % size)
        let y = CGFloat((index * 97 + seed * 3) % size)
        context.fillEllipse(in: CGRect(x: x - 60, y: y - 60, width: 120, height: 120))
    }
    guard let image = context.makeImage() else {
        fatalError("이미지를 만들 수 없어요")
    }
    return image
}

/// 지정한 장치를 쓸 수 있는 Vision 요청을 골라 그 장치로 고정해요.
func makeRequest(for target: Target) throws -> (request: VNRequest, name: String)? {
    let candidates: [(VNRequest, String)] = [
        (VNClassifyImageRequest(), "이미지 분류"),
        (VNGenerateImageFeaturePrintRequest(), "이미지 특징 추출"),
    ]
    for (request, name) in candidates {
        let devices = try request.supportedComputeStageDevices[.main] ?? []
        log("- \(name) 요청이 쓸 수 있는 장치: \(devices.map(describe).joined(separator: ", "))")
        if let device = devices.first(where: target.matches) {
            request.setComputeDevice(device, for: .main)
            return (request, name)
        }
    }
    return nil
}

let arguments = CommandLine.arguments
let seconds = arguments.count > 1 ? (Double(arguments[1]) ?? 30) : 30
let target = arguments.count > 2 ? (Target(rawValue: arguments[2]) ?? .ane) : .ane

log("목표 장치: \(target.rawValue), 실행 시간: \(Int(seconds))초")
guard let picked = try makeRequest(for: target) else {
    log("⚠️ \(target.rawValue)에서 돌릴 수 있는 Vision 요청을 찾지 못했어요.")
    exit(2)
}

let images = (0..<16).map { makeImage(seed: $0) }
log("\(picked.name) 요청을 \(target.rawValue)에서 반복해요…")

let start = Date()
var count = 0
var nextReport = 5.0
while true {
    let elapsed = Date().timeIntervalSince(start)
    if elapsed >= seconds { break }
    let handler = VNImageRequestHandler(cgImage: images[count % images.count], options: [:])
    try handler.perform([picked.request])
    count += 1
    if elapsed >= nextReport {
        log(String(format: "%.0f초: %d회", elapsed, count))
        nextReport += 5
    }
}
let total = Date().timeIntervalSince(start)
log(String(format: "완료: %d회, 초당 %.1f회 (%@, %@)", count, Double(count) / total, picked.name, target.rawValue))
