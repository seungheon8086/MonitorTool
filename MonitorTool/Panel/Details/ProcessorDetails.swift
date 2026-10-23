import SwiftUI

// CPU·GPU·ANE 열을 눌렀을 때 카드 아래로 펼쳐지는 상세예요. (화면과 같은 순서로 놓았어요)
// 그래프(1분·5분·30분)는 다음 작업(3-2)에서 붙여요.

struct CPUDetail: View {
    @Environment(MonitorStore.self) private var store
    @Environment(AppearanceSettings.self) private var appearance

    var body: some View {
        let cpu = store.snapshot.cpu
        DetailCard(title: "CPU 자세히") {
            HStack(alignment: .top, spacing: 8) {
                LabeledValue(label: "E 코어", reading: cpu.efficiencyUsage, format: ValueFormat.percent)
                LabeledValue(label: "P 코어", reading: cpu.performanceUsage, format: ValueFormat.percent)
                LabeledValue(label: "전력", reading: cpu.power, format: ValueFormat.watts)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("코어별 사용률")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                if cpu.cores.isEmpty {
                    StateText(state: .preparing)
                } else {
                    CoreBars(groups: cpu.coreGroups, color: appearance.color(for: .cpu))
                }
            }
            SourceNote(text: "사용률은 OS가 집계한 CPU 시간이에요. 전력은 보조 프로그램이 powermetrics로 잰 CPU 전체 값(1초 구간 평균)이에요.")
        }
    }
}

/// 코어별 사용률 막대. 묶음(E, P 묶음 1, P 묶음 2)별로 모아서 보여줘요.
struct CoreBars: View {
    let groups: [CoreGroup]
    let color: ItemColor

    private static let barHeight: CGFloat = 40

    var body: some View {
        HStack(alignment: .bottom, spacing: 14) {
            ForEach(groups) { group in
                VStack(spacing: 4) {
                    HStack(alignment: .bottom, spacing: 3) {
                        ForEach(group.cores) { core in
                            UnevenRoundedRectangle(topLeadingRadius: 3, topTrailingRadius: 3, style: .continuous)
                                .fill(group.kind == .efficiency ? color.secondaryColor : color.color)
                                .frame(width: 14, height: max(2, Self.barHeight * min(core.usage, 100) / 100))
                                .help(Text("CPU \(core.id) · \(ValueFormat.percent(core.usage))"))
                        }
                    }
                    .frame(height: Self.barHeight, alignment: .bottom)
                    Text(group.title)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("코어별 사용률"))
    }
}

struct GPUDetail: View {
    @Environment(MonitorStore.self) private var store

    var body: some View {
        let gpu = store.snapshot.gpu
        DetailCard(title: "GPU 자세히") {
            HStack(alignment: .top, spacing: 8) {
                LabeledValue(label: "사용률", reading: gpu.usage, format: ValueFormat.percent)
                LabeledValue(label: "전력", reading: gpu.power, format: ValueFormat.watts)
            }
            SourceNote(text: "사용률은 GPU 드라이버가 알려 주는 값(Device Utilization)이에요. 전력은 권한 없이 읽는 GPU 에너지 카운터로 계산해요.")
        }
    }
}

struct ANEDetail: View {
    @Environment(MonitorStore.self) private var store

    var body: some View {
        let ane = store.snapshot.ane
        DetailCard(title: "ANE (Neural Engine) 자세히", trailing: activeSinceText(ane)) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("상태")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    ANEActivityLabel(reading: ane.isActive)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                LabeledValue(label: "전력", reading: ane.power, format: ValueFormat.watts)
                LabeledValue(label: "ANE 온도", reading: ane.temperature, format: ValueFormat.celsius)
            }
            HStack(alignment: .firstTextBaseline) {
                Text("ANE의 DRAM 트래픽")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                ValueText(reading: ane.dramTraffic, format: ValueFormat.gigabytesPerSecond,
                          font: .system(size: 13, weight: .semibold))
            }
            InfoBox(text: "사용률(%)은 보여 드리지 않아요. macOS가 ANE가 일한 시간의 비율을 알려 주지 않기 때문이에요. '사용 중'은 ANE 전원이 켜져 있는지로 판단해요. 일한 양은 트래픽으로 가늠할 수 있어요.")
            SourceNote(text: "전력: 보조 프로그램(powermetrics) · 트래픽: 메모리 컨트롤러의 ANE0 DRAM 값 · 온도: ANE 센서 중 최고값(켜져 있을 때만)")
        }
    }

    /// '18:45:48부터 사용 중'
    private func activeSinceText(_ ane: ANESnapshot) -> String? {
        guard ane.isActive.okValue == true, let since = ane.activeSince else { return nil }
        return "\(ValueFormat.clock(since))부터 사용 중"
    }
}
