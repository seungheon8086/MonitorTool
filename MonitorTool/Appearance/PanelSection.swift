import Foundation

/// 패널에 위에서부터 놓이는 카드 덩어리예요. 순서는 설정 창 '모양 > 항목 순서'에서 바꿔요. (2026-11-03 사용자 요청)
/// 맨 위 3열 카드(CPU·GPU·ANE)는 한 덩어리로 옮기고, 카드 안 열 순서는 따로 바꿔요.
enum PanelSection: String, CaseIterable, Identifiable {
    case processor, memory, thermal, battery, disk, network

    var id: Self { self }

    var title: String {
        switch self {
        case .processor: "CPU · GPU · ANE"
        case .memory: "메모리"
        case .thermal: "온도·팬"
        case .battery: "배터리"
        case .disk: "디스크"
        case .network: "네트워크"
        }
    }

    /// 이 덩어리에 든 항목이에요. (맨 위 카드는 기본 열 순서)
    var items: [MonitorItem] {
        switch self {
        case .processor: Self.processorItems
        case .memory: [.memory]
        case .thermal: [.thermal]
        case .battery: [.battery]
        case .disk: [.disk]
        case .network: [.network]
        }
    }

    /// 맨 위 카드의 기본 열 순서 (2026-10-24 사용자 결정)
    static let processorItems: [MonitorItem] = [.cpu, .gpu, .ane]

    /// 저장된 순서를 정리해요: 모르는 값·겹친 값은 빼고, 빠진 값은 기본 순서에서 바로 앞에 오는 값 뒤에 끼워요.
    /// (앞으로 항목이 늘거나 줄어도 저장된 순서가 깨지지 않게. 예: 새 '디스크'는 저장된 순서에서도 배터리 바로 뒤)
    static func normalized<T: Hashable>(_ saved: [T], all: [T]) -> [T] {
        var seen = Set<T>()
        var result: [T] = []
        for value in saved where all.contains(value) && seen.insert(value).inserted {
            result.append(value)
        }
        for (index, value) in all.enumerated() where !seen.contains(value) {
            var position = 0
            for earlier in all[..<index].reversed() {
                if let found = result.firstIndex(of: earlier) {
                    position = found + 1
                    break
                }
            }
            result.insert(value, at: position)
            seen.insert(value)
        }
        return result
    }

    /// `value`를 `target` 자리로 옮긴 순서예요. 아래로 옮기면 `target` 뒤, 위로 옮기면 `target` 앞에 놓여요.
    static func moving<T: Equatable>(_ value: T, onto target: T, in list: [T]) -> [T] {
        guard let from = list.firstIndex(of: value), let to = list.firstIndex(of: target), from != to else {
            return list
        }
        var result = list
        result.remove(at: from)
        result.insert(value, at: to)
        return result
    }

    /// 한 칸 위(−1)·아래(+1)로 옮긴 순서예요. (손쉬운 사용 동작용)
    static func shifting<T: Equatable>(_ value: T, by offset: Int, in list: [T]) -> [T] {
        guard let from = list.firstIndex(of: value) else { return list }
        let to = from + offset
        guard list.indices.contains(to) else { return list }
        var result = list
        result.swapAt(from, to)
        return result
    }
}
