import SwiftUI

// 그래프 제목 줄에 붙는 작은 조각들(범례, 지금 값, 기간·단위 고르기)이에요.

/// 범례의 색 막대예요. 점선 계열은 점선으로 보여줘요.
struct LegendSwatch: View {
    let color: Color
    var dashed: Bool = false

    var body: some View {
        if dashed {
            Path { path in
                path.move(to: CGPoint(x: 0, y: 1))
                path.addLine(to: CGPoint(x: 10, y: 1))
            }
            .stroke(color, style: StrokeStyle(lineWidth: 2, dash: [3, 2]))
            .frame(width: 10, height: 2)
        } else {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(color)
                .frame(width: 10, height: 3)
        }
    }
}

/// 범례 한 칸: 색 막대 + 이름 (예: '▬ 오른쪽')
struct LegendLabel: View {
    let color: Color
    var dashed: Bool = false
    let label: String

    var body: some View {
        HStack(spacing: 4) {
            LegendSwatch(color: color, dashed: dashed)
            Text(label)
        }
        .font(.system(size: 12))
    }
}

/// 범례 한 칸에 지금 값까지 (예: '▬ E 34%')
struct LegendValue: View {
    let color: Color
    var dashed: Bool = false
    let label: String
    let reading: Reading<Double>
    let format: (Double) -> String

    var body: some View {
        HStack(spacing: 4) {
            LegendSwatch(color: color, dashed: dashed)
            Text(label)
            // 정상이면 숫자, 갱신이 멈췄으면 흐린 숫자와 시계, 그 밖에는 상태를 보여줘요.
            ValueText(reading: reading, format: format, font: .system(size: 12))
        }
        .font(.system(size: 12))
    }
}

/// 그래프 제목 줄 오른쪽: 지금 값과 기간 평균 (예: '2.3 W · 1분 평균 2.1 W')
struct ValueWithAverage: View {
    @Environment(MonitorStore.self) private var store

    let reading: Reading<Double>
    let metric: Metric
    let period: ChartPeriod
    let format: (Double) -> String

    var body: some View {
        if let value = reading.okValue {
            Text(text(for: value))
                .font(.system(size: 12))
                .monospacedDigit()
        } else {
            // 갱신이 멈춘 값은 평균 없이 흐린 숫자와 시계만, 그 밖에는 상태를 보여줘요.
            ValueText(reading: reading, format: format, font: .system(size: 12))
        }
    }

    private func text(for value: Double) -> String {
        let end = store.snapshot.takenAt ?? .now
        let start = end.addingTimeInterval(-period.duration)
        guard let average = store.history.average(for: metric, from: start, to: end) else {
            return format(value)
        }
        return "\(format(value)) · \(period.title) 평균 \(format(average))"
    }
}

/// 그래프 기간 고르기 (1분·5분·30분)
struct PeriodPicker: View {
    @Binding var period: ChartPeriod

    var body: some View {
        Picker("그래프 기간", selection: $period) {
            ForEach(ChartPeriod.allCases) { option in
                Text(option.title)
                    .tag(option)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .fixedSize()
    }
}

/// 네트워크 속도 단위 고르기 (MB/s │ Mbps). 설정 창 '일반 > 단위'와 같은 값이라, 바꾸면 카드·위젯도 함께 바뀌어요. (2026-11-20 사용자 요청, #3)
struct NetworkRateUnitPicker: View {
    @Environment(AppearanceSettings.self) private var appearance

    var body: some View {
        Picker("네트워크 속도 단위", selection: unit) {
            ForEach(NetworkRateUnit.allCases) { option in
                Text(option.title)
                    .tag(option)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .fixedSize()
    }

    private var unit: Binding<NetworkRateUnit> {
        Binding(get: { appearance.networkRateUnit },
                set: { appearance.setNetworkRateUnit($0) })
    }
}
