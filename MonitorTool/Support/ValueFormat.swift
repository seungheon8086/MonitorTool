import Foundation

/// 화면에 보여줄 숫자 모양을 한곳에서 정해요.
nonisolated enum ValueFormat {
    /// 숫자로 보여줄 수 없는 값(무한대·NaN 등)일 때 쓰는 표시예요.
    /// 수집기가 잘못된 값을 넘겨도 앱이 멈추지 않게 하는 마지막 안전장치예요.
    static let unavailable = "—"

    /// 34%
    static func percent(_ value: Double) -> String {
        guard let number = whole(value) else { return unavailable }
        return "\(number)%"
    }

    /// 2.3 W
    static func watts(_ value: Double) -> String {
        guard value.isFinite else { return unavailable }
        return "\(oneDecimal(value)) W"
    }

    /// 배터리 순전력처럼 부호가 있는 W: +12.0 W, −11.2 W
    static func signedWatts(_ value: Double) -> String {
        guard value.isFinite else { return unavailable }
        let magnitude = oneDecimal(abs(value))
        if value >= 0.05 { return "+\(magnitude) W" }
        if value <= -0.05 { return "−\(magnitude) W" }
        return "0.0 W"
    }

    /// 61 °C
    static func celsius(_ value: Double) -> String {
        guard let number = whole(value) else { return unavailable }
        return "\(number) °C"
    }

    /// 2,140 RPM
    static func rpm(_ value: Double) -> String {
        guard let number = whole(value) else { return unavailable }
        return "\(number.formatted()) RPM"
    }

    /// 메모리 크기 숫자만: 11.4, 16 (1 GB = 1024³ 바이트, macOS 표기와 같아요)
    static func memoryNumber(_ bytes: Double) -> String {
        let gigabytes = (bytes / 1_073_741_824 * 10).rounded() / 10
        guard let number = whole(gigabytes) else { return unavailable }
        if Double(number) == gigabytes {
            return "\(number)"
        }
        return oneDecimal(gigabytes)
    }

    /// 메모리 크기: 1.3 GB
    static func memory(_ bytes: Double) -> String {
        guard bytes.isFinite else { return unavailable }
        return "\(memoryNumber(bytes)) GB"
    }

    /// DRAM 트래픽 숫자만: 3.6 (1 GB = 10⁹ 바이트)
    static func gigabytesPerSecondNumber(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond.isFinite else { return unavailable }
        return oneDecimal(bytesPerSecond / 1_000_000_000)
    }

    /// DRAM 트래픽: 9.8 GB/s
    static func gigabytesPerSecond(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond.isFinite else { return unavailable }
        return "\(gigabytesPerSecondNumber(bytesPerSecond)) GB/s"
    }

    /// 데이터 양: 96 KB, 410 MB, 3.2 GB (1 KB = 1000 바이트)
    static func byteCount(_ bytes: Double) -> String {
        guard bytes.isFinite else { return unavailable }
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = max(bytes, 0)
        var index = 0
        while value >= 1000, index < units.count - 1 {
            value /= 1000
            index += 1
        }
        // 바이트 단위이거나 10 이상이면 소수점 없이 보여줘요. (예: 96 KB, 410 MB, 1.8 MB)
        if index == 0 || value >= 10, let number = whole(value) {
            return "\(number) \(units[index])"
        }
        return "\(oneDecimal(value)) \(units[index])"
    }

    /// 네트워크 속도: 96 KB/s, 1.8 MB/s
    static func rate(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond.isFinite else { return unavailable }
        return "\(byteCount(bytesPerSecond))/s"
    }

    /// 그래프 눈금용 짧은 숫자: 8, 1.5, 5,000 (정수면 소수점 없이)
    static func compact(_ value: Double) -> String {
        guard let number = whole(value) else { return unavailable }
        if Double(number) == value {
            return number.formatted()
        }
        return oneDecimal(value)
    }

    /// 그래프 눈금: 8 W
    static func wattsScale(_ value: Double) -> String {
        "\(compact(value)) W"
    }

    /// 그래프 눈금: 6 GB/s (1 GB = 10⁹ 바이트)
    static func gigabytesPerSecondScale(_ bytesPerSecond: Double) -> String {
        "\(compact(bytesPerSecond / 1_000_000_000)) GB/s"
    }

    /// 그래프 눈금: 500 KB/s, 4 MB/s (1 KB = 1000 바이트)
    static func rateScale(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond.isFinite else { return unavailable }
        let units = ["B/s", "KB/s", "MB/s", "GB/s"]
        var value = max(bytesPerSecond, 0)
        var index = 0
        while value >= 1000, index < units.count - 1 {
            value /= 1000
            index += 1
        }
        return "\(compact(value)) \(units[index])"
    }

    /// 걸리는 시간: 4시간 20분
    static func duration(_ seconds: Double) -> String {
        guard let totalMinutes = whole(max(seconds, 0) / 60) else { return unavailable }
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours > 0 {
            return minutes > 0 ? "\(hours)시간 \(minutes)분" : "\(hours)시간"
        }
        return "\(minutes)분"
    }

    /// 18:46:12 (24시간 표기)
    static func clock(_ date: Date) -> String {
        clockFormatter.string(from: date)
    }

    /// 18:02 (24시간 표기)
    static func clockMinutes(_ date: Date) -> String {
        String(clock(date).prefix(5))
    }

    /// 10월 23일
    static func monthDay(_ date: Date) -> String {
        date.formatted(.dateTime.month().day())
    }

    /// 반올림한 정수예요. 정수로 바꿀 수 없는 값(무한대·NaN·너무 큰 값)이면 nil이에요.
    /// (Int(Double)는 이런 값을 받으면 앱을 멈추게 해서 미리 걸러요.)
    private static func whole(_ value: Double) -> Int? {
        let rounded = value.rounded()
        guard rounded.isFinite, abs(rounded) < 1e15 else { return nil }
        return Int(rounded)
    }

    private static func oneDecimal(_ value: Double) -> String {
        String(format: "%.1f", value)
    }

    /// DateFormatter는 여러 스레드에서 함께 써도 되는 타입(Sendable)이라 그대로 둬요.
    private static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}
