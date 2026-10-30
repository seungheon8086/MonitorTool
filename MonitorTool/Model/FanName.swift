import Foundation

/// 팬 이름과 그래프에서 연하게 그릴 팬을 한 곳에서 정해요. (docs/FAN_CONTROL.md '팬 이름')
/// 팬이 두 개면 SMC 0번 = 왼쪽(최대 4,296), 1번 = 오른쪽(최대 4,744) — MacBookPro18,1에서 확인했어요.
/// 팬 수가 다른 Mac은 '팬 1', '팬 2'…로 부르고 첫 팬 말고는 연하게 그려요.
nonisolated enum FanName {
    /// 짧은 이름: '왼쪽', '오른쪽' (팬 칸·그래프 범례)
    static func short(id: Int, count: Int) -> String {
        guard count == 2 else {
            return "팬 \(id + 1)"
        }
        return id == 0 ? "왼쪽" : "오른쪽"
    }

    /// 긴 이름: '왼쪽 팬', '오른쪽 팬' (카드·위젯 항목)
    static func long(id: Int, count: Int) -> String {
        guard count == 2 else {
            return "팬 \(id + 1)"
        }
        return id == 0 ? "왼쪽 팬" : "오른쪽 팬"
    }

    /// 같은 색을 연하게, 점선으로 그릴 팬인지 (두 개면 왼쪽)
    static func isLight(id: Int, count: Int) -> Bool {
        count == 2 ? id == 0 : id > 0
    }
}
