import AppIntents
import Foundation

/// 위젯의 '상세 보기/요약 보기' 버튼이 실행하는 동작이에요.
/// 화면 상태만 위젯 쪽에 저장하고, 공유 폴더의 측정 데이터는 건드리지 않아요.
struct ToggleDetailIntent: AppIntent {
    static let title: LocalizedStringResource = "위젯 상세 화면 전환"

    func perform() async throws -> some IntentResult {
        ProbeWidgetState.showDetail.toggle()
        return .result()
    }
}

/// 위젯이 지금 상세 화면을 보여주는지 (위젯 확장 자신의 설정에 저장)
enum ProbeWidgetState {
    private static let key = "showDetail"

    static var showDetail: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}
