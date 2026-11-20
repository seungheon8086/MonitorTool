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
        return decimalUnits(bytes, units: ["B", "KB", "MB", "GB", "TB"])
    }

    /// 속도: 96 KB/s, 1.8 MB/s (디스크 읽기·쓰기는 늘 이 꼴이에요)
    static func rate(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond.isFinite else { return unavailable }
        return "\(byteCount(bytesPerSecond))/s"
    }

    /// 네트워크 속도: 바이트면 96 KB/s, 1.8 MB/s · 비트면 768 Kbps, 14 Mbps (1 Kbps = 1000 bps)
    static func networkRate(_ bytesPerSecond: Double, unit: NetworkRateUnit) -> String {
        guard bytesPerSecond.isFinite else { return unavailable }
        switch unit {
        case .bytes:
            return rate(bytesPerSecond)
        case .bits:
            return decimalUnits(bytesPerSecond * unit.factor, units: bitRateUnits)
        }
    }

    /// 평균 동시 요청 수: 1.6 (소수 한 자리)
    static func queueDepth(_ value: Double) -> String {
        guard value.isFinite else { return unavailable }
        return oneDecimal(max(value, 0))
    }

    /// 응답 시간(초)을 ms로: 0.28 ms, 4.80 ms, 12 ms
    static func milliseconds(_ seconds: Double) -> String {
        guard seconds.isFinite else { return unavailable }
        let value = max(seconds, 0) * 1000
        if value >= 10, let number = whole(value) {
            return "\(number.formatted()) ms"
        }
        return String(format: "%.2f ms", value)
    }

    /// 개수: 1,180
    static func count(_ value: Double) -> String {
        guard let number = whole(max(value, 0)) else { return unavailable }
        return number.formatted()
    }

    /// 그래프 눈금용 짧은 숫자: 8, 1.5, 0.75, 5,000 (정수면 소수점 없이, 가운데 눈금 0.75처럼 필요하면 소수 둘째 자리까지)
    static func compact(_ value: Double) -> String {
        guard let number = whole(value) else { return unavailable }
        if Double(number) == value {
            return number.formatted()
        }
        let tenths = (value * 10).rounded() / 10
        if abs(value - tenths) < 0.000_001 {
            return oneDecimal(value)
        }
        return String(format: "%.2f", value)
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
        return compactUnits(bytesPerSecond, units: ["B/s", "KB/s", "MB/s", "GB/s"])
    }

    /// 네트워크 그래프 눈금: 바이트면 500 KB/s, 4 MB/s · 비트면 800 Kbps, 10 Mbps
    static func networkRateScale(_ bytesPerSecond: Double, unit: NetworkRateUnit) -> String {
        guard bytesPerSecond.isFinite else { return unavailable }
        switch unit {
        case .bytes:
            return rateScale(bytesPerSecond)
        case .bits:
            return compactUnits(bytesPerSecond * unit.factor, units: Array(bitRateUnits.dropLast()))
        }
    }

    private static let bitRateUnits = ["bps", "Kbps", "Mbps", "Gbps", "Tbps"]

    /// 1000마다 다음 단위로 올려요. 가장 작은 단위이거나 10 이상이면 정수, 그 밖은 소수 한 자리예요.
    /// (예: 96 KB, 410 MB, 1.8 MB / 768 Kbps, 14 Mbps, 7.6 Kbps)
    private static func decimalUnits(_ value: Double, units: [String]) -> String {
        let (value, unit) = stepUp(value, units: units)
        if unit == units[0] || value >= 10, let number = whole(value) {
            return "\(number) \(unit)"
        }
        return "\(oneDecimal(value)) \(unit)"
    }

    /// 그래프 눈금용: 1000마다 다음 단위로 올리고 숫자는 compact로 써요. (예: 500 KB/s, 1.5 Mbps)
    private static func compactUnits(_ value: Double, units: [String]) -> String {
        let (value, unit) = stepUp(value, units: units)
        return "\(compact(value)) \(unit)"
    }

    private static func stepUp(_ value: Double, units: [String]) -> (Double, String) {
        var value = max(value, 0)
        var index = 0
        while value >= 1000, index < units.count - 1 {
            value /= 1000
            index += 1
        }
        return (value, units[index])
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

    /// 값이 얼마나 오래됐는지: 12초, 3분, 2시간 (뒤에 '전 값'을 붙여 써요)
    static func age(_ seconds: Int) -> String {
        let seconds = max(seconds, 0)
        if seconds < 60 { return "\(seconds)초" }
        if seconds < 3600 { return "\(seconds / 60)분" }
        return "\(seconds / 3600)시간"
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
