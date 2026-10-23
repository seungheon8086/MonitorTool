import Foundation
import SwiftUI

// 메모리·온도·팬·배터리·네트워크 카드를 눌렀을 때 아래로 펼쳐지는 상세예요.
// 그래프(1분·5분·30분)는 다음 작업(3-2)에서 붙여요.

// MARK: - 메모리

struct MemoryDetail: View {
    @Environment(MonitorStore.self) private var store

    var body: some View {
        let memory = store.snapshot.memory
        DetailCard(title: "메모리 자세히") {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("메모리 압력")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    PressureValue(reading: memory.pressure)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                LabeledValue(label: "압축", reading: memory.compressed, format: ValueFormat.memory,
                             font: .system(size: 14, weight: .semibold))
                LabeledValue(label: "스왑", reading: memory.swapUsed, format: ValueFormat.memory,
                             font: .system(size: 14, weight: .semibold))
            }
            Divider()
            HStack(alignment: .firstTextBaseline) {
                Text("DRAM 트래픽")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                ReadWriteText(read: memory.trafficRead, write: memory.trafficWrite)
            }
            DeviceTrafficGrid(memory: memory)
            SourceNote(text: "트래픽은 실제로 DRAM까지 간 양이에요(GB/s). 칩 안 캐시에서 끝난 요청은 빼요.")
        }
    }
}

/// 상세 화면의 메모리 압력 ('● 정상')
struct PressureValue: View {
    let reading: Reading<MemoryPressure>

    var body: some View {
        if let pressure = reading.okValue {
            HStack(spacing: 6) {
                Circle()
                    .fill(color(for: pressure))
                    .frame(width: 7, height: 7)
                Text(title(for: pressure))
                    .font(.system(size: 14, weight: .semibold))
            }
        } else {
            StateText(state: reading.state)
        }
    }

    private func title(for pressure: MemoryPressure) -> String {
        switch pressure {
        case .normal: "정상"
        case .warning: "주의"
        case .critical: "높음"
        }
    }

    private func color(for pressure: MemoryPressure) -> Color {
        switch pressure {
        case .normal: StatusColor.active
        case .warning: Color.yellow
        case .critical: StatusColor.error
        }
    }
}

/// '읽기 6.1 · 쓰기 3.7 GB/s'
struct ReadWriteText: View {
    let read: Reading<Double>
    let write: Reading<Double>

    var body: some View {
        if let readBytes = read.okValue, let writeBytes = write.okValue {
            Text("읽기 \(ValueFormat.gigabytesPerSecondNumber(readBytes)) · 쓰기 \(ValueFormat.gigabytesPerSecondNumber(writeBytes)) GB/s")
                .font(.system(size: 12))
                .monospacedDigit()
        } else {
            StateText(state: read.state == .ok ? write.state : read.state)
        }
    }
}

/// 기기별 DRAM 트래픽. CPU·GPU·ANE는 항목 색, 나머지는 회색이에요.
struct DeviceTrafficGrid: View {
    let memory: MemorySnapshot
    @Environment(AppearanceSettings.self) private var appearance

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), alignment: .leading), count: 3)
    }

    var body: some View {
        if memory.trafficByDevice.isEmpty {
            StateText(state: memory.trafficTotal.state)
        } else {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
                ForEach(memory.trafficByDevice) { traffic in
                    ColorChip(color: color(for: traffic.device),
                              text: "\(name(for: traffic.device)) \(ValueFormat.gigabytesPerSecondNumber(traffic.bytesPerSecond))")
                }
            }
        }
    }

    private func name(for device: TrafficDevice) -> String {
        switch device {
        case .cpu: "CPU"
        case .gpu: "GPU"
        case .ane: "ANE"
        case .display: "화면"
        case .storage: "저장장치"
        case .other: "그 밖"
        }
    }

    private func color(for device: TrafficDevice) -> Color {
        switch device {
        case .cpu: appearance.color(for: .cpu).color
        case .gpu: appearance.color(for: .gpu).color
        case .ane: appearance.color(for: .ane).color
        case .display, .storage, .other: Color.gray.opacity(0.6)
        }
    }
}

// MARK: - 온도·팬

struct ThermalDetail: View {
    @Environment(MonitorStore.self) private var store

    var body: some View {
        let thermal = store.snapshot.thermal
        let ane = store.snapshot.ane
        DetailCard(title: "온도·팬 자세히") {
            VStack(spacing: 0) {
                ListRow(title: "CPU 최고", note: "코어 센서 10개") {
                    ValueText(reading: thermal.cpuMax, format: ValueFormat.celsius, font: Self.valueFont)
                }
                Divider()
                ListRow(title: "GPU 최고", note: "센서 2개") {
                    ValueText(reading: thermal.gpuMax, format: ValueFormat.celsius, font: Self.valueFont)
                }
                Divider()
                ListRow(title: "ANE", note: "켜져 있을 때만") {
                    ValueText(reading: ane.temperature, format: ValueFormat.celsius, font: Self.valueFont)
                }
                Divider()
                ListRow(title: "배터리") {
                    ValueText(reading: thermal.battery, format: ValueFormat.celsius, font: Self.valueFont)
                }
                Divider()
                ListRow(title: "SSD") {
                    ValueText(reading: thermal.ssd, format: ValueFormat.celsius, font: Self.valueFont)
                }
            }
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            FanCards(fans: thermal.fans)
            SourceNote(text: "온도는 SMC 센서에서 읽어요. CPU·GPU 최고는 부하 실험으로 고른 센서 중 가장 높은 값이에요. 칩 전체의 절대 최고 온도는 아니에요.")
        }
    }

    private static let valueFont = Font.system(size: 12, weight: .semibold)
}

/// 팬마다 회전수, 범위, 모드를 보여줘요.
struct FanCards: View {
    let fans: Reading<[FanReading]>

    private var columns: [GridItem] {
        [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)]
    }

    var body: some View {
        if let list = fans.okValue {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                ForEach(list) { fan in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title(for: fan))
                            .font(.system(size: 12, weight: .semibold))
                        Text(rangeText(for: fan))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        Text("모드: \(modeText(for: fan.mode))")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
        } else {
            HStack {
                Text("팬")
                    .font(.system(size: 12))
                Spacer(minLength: 8)
                StateText(state: fans.state)
            }
        }
    }

    /// '팬 1 · 정지', '팬 2 · 2,140 RPM'
    private func title(for fan: FanReading) -> String {
        let number = fan.id + 1
        guard let rpm = fan.rpm.okValue else { return "팬 \(number) · 읽지 못함" }
        return rpm < 1 ? "팬 \(number) · 정지" : "팬 \(number) · \(ValueFormat.rpm(rpm))"
    }

    /// '0 RPM · 범위 1,499–4,296'
    private func rangeText(for fan: FanReading) -> String {
        let current = fan.rpm.okValue.map(ValueFormat.rpm) ?? "—"
        guard let minimum = fan.minimumRPM, let maximum = fan.maximumRPM else { return current }
        let range = "\(Int(minimum.rounded()).formatted())–\(Int(maximum.rounded()).formatted())"
        return "\(current) · 범위 \(range)"
    }

    private func modeText(for mode: FanMode) -> String {
        switch mode {
        case .automatic: "시스템 자동"
        case .manual: "수동"
        case .unknown: "알 수 없음"
        }
    }
}

// MARK: - 배터리

struct BatteryDetail: View {
    @Environment(MonitorStore.self) private var store

    var body: some View {
        let battery = store.snapshot.battery
        DetailCard(title: "배터리 자세히") {
            HStack(alignment: .top, spacing: 8) {
                LabeledValue(label: "성능 상태", reading: battery.condition, format: { $0 },
                             font: .system(size: 14, weight: .semibold))
                LabeledValue(label: "최대 용량", reading: battery.maximumCapacity, format: ValueFormat.percent,
                             font: .system(size: 14, weight: .semibold))
                LabeledValue(label: "사이클 수", reading: battery.cycleCount, format: { "\($0.formatted())회" },
                             font: .system(size: 14, weight: .semibold))
            }
            HStack(alignment: .firstTextBaseline) {
                Text("순전력")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                ValueText(reading: battery.netPower, format: ValueFormat.signedWatts,
                          font: .system(size: 13, weight: .semibold))
            }
            SourceNote(text: "순전력은 배터리로 들어가고 나오는 전력이에요. 충전기 출력이나 Mac 전체 소비전력과는 달라요. 남은 시간은 macOS가 추정한 값이에요.")
        }
    }
}

// MARK: - 네트워크

struct NetworkDetail: View {
    @Environment(MonitorStore.self) private var store

    var body: some View {
        let network = store.snapshot.network
        DetailCard(title: "네트워크 자세히") {
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 7) {
                GridRow {
                    Text("누적")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text("↓ 받음")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .gridColumnAlignment(.trailing)
                    Text("↑ 보냄")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .gridColumnAlignment(.trailing)
                }
                Divider()
                GridRow {
                    TotalTitle(title: "오늘", detail: network.todayDate.map(ValueFormat.monthDay))
                    ValueText(reading: network.todayDownloaded, format: ValueFormat.byteCount, font: Self.valueFont)
                    ValueText(reading: network.todayUploaded, format: ValueFormat.byteCount, font: Self.valueFont)
                }
                Divider()
                GridRow {
                    TotalTitle(title: "이번 실행",
                               detail: network.sessionStartedAt.map { "\(ValueFormat.clockMinutes($0))부터" })
                    ValueText(reading: network.sessionDownloaded, format: ValueFormat.byteCount, font: Self.valueFont)
                    ValueText(reading: network.sessionUploaded, format: ValueFormat.byteCount, font: Self.valueFont)
                }
            }
            .padding(10)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text("인터페이스")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                if network.interfaces.isEmpty {
                    StateText(state: network.download.state)
                } else {
                    ForEach(network.interfaces) { interface in
                        HStack(spacing: 4) {
                            Text(interface.displayName)
                            Text("(\(interface.id))")
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 8)
                            Text("↓ \(ValueFormat.rate(interface.download)) · ↑ \(ValueFormat.rate(interface.upload))")
                                .monospacedDigit()
                        }
                        .font(.system(size: 12))
                    }
                }
            }
            SourceNote(text: "오늘 누적은 앱이 켜져 있는 동안 관측한 양이에요. VPN 같은 가상 인터페이스는 실제 전송과 겹쳐 세지 않아요.")
        }
    }

    private static let valueFont = Font.system(size: 12, weight: .semibold)
}

/// '오늘 · 10월 23일'
private struct TotalTitle: View {
    let title: String
    let detail: String?

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
                .font(.system(size: 12))
            if let detail {
                Text("· \(detail)")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
    }
}
