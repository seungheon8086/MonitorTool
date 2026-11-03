import AppKit
import Darwin

/// 창 뒤 배경을 흐리게 해요. (패널 배경 설정 '배경 흐림', 2026-11-03 사용자 요청)
///
/// 흐림 세기를 정하는 공개 기능이 없어서, iTerm2·Alacritty가 '창 뒤 흐림'에 쓰는 비공개 CoreGraphics 함수
/// `CGSSetWindowBackgroundBlurRadius`를 dlsym으로 찾아 불러요. 함수를 못 찾거나 실패하면 흐림 없이 그대로 둬요.
/// (외부 배포하지 않는 개인 앱이라 비공개 함수를 써요)
enum WindowBlur {
    private typealias MainConnectionFunction = @convention(c) () -> Int32
    private typealias SetBlurRadiusFunction = @convention(c) (Int32, Int32, Int32) -> Int32

    /// 이 Mac에서 쓸 수 있는지 (함수를 찾았는지)
    static var isAvailable: Bool {
        mainConnection != nil && setBlurRadius != nil
    }

    /// 창 뒤 흐림 반지름 (0이면 끔). 성공하면 true예요.
    @discardableResult
    static func apply(radius: Int, to window: NSWindow) -> Bool {
        guard let mainConnection, let setBlurRadius, window.windowNumber > 0 else { return false }
        let result = setBlurRadius(mainConnection(), Int32(clamping: window.windowNumber), Int32(clamping: max(radius, 0)))
        if result != 0 {
            print("⚠️ 배경 흐림: CGSSetWindowBackgroundBlurRadius 실패 \(result)")
        }
        return result == 0
    }

    private static let mainConnection: MainConnectionFunction? = symbol("CGSMainConnectionID")
    private static let setBlurRadius: SetBlurRadiusFunction? = symbol("CGSSetWindowBackgroundBlurRadius")

    private static func symbol<Function>(_ name: String) -> Function? {
        // RTLD_DEFAULT: 이미 불러온 모든 라이브러리(CoreGraphics 포함)에서 찾아요.
        guard let pointer = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) else {
            print("⚠️ 배경 흐림: \(name)을 찾지 못함")
            return nil
        }
        return unsafeBitCast(pointer, to: Function.self)
    }
}
