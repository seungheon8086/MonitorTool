import Foundation
import SwiftUI

/// 디스크 카드를 눌렀을 때 펼쳐지는 상세 (화면 시안 '디스크 B안', docs/DISK_IO.md)
/// 맨 위에서 디스크를 골라 한 디스크씩 봐요. 디스크가 하나면 고르기는 숨겨요.
struct DiskDetail: View {
    @Environment(MonitorStore.self) private var store
    @Environment(AppearanceSettings.self) private var appearance
    @AppStorage("chartPeriod.disk") private var period: ChartPeriod = .oneMinute
    /// 고른 디스크의 고정 키. 고른 디스크가 빠지면 첫 디스크를 보여줘요.
    @AppStorage("diskDetailSelection") private var selectedKey = ""

    var body: some View {
        let state = store.snapshot.disk.disks
        DetailCard(title: "디스크 자세히") {
            PeriodPicker(period: $period)
        } content: {
            if let disks = state.okValue, let disk = current(in: disks) {
                if disks.count > 1 {
                    picker(disks, current: disk)
                }
                Text("\(disk.model) · \(disk.isInternal ? "내장" : "외장")")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                activeChart(disk)
                speedChart(disk)
                queueChart(disk)
                DiskValueTable(disk: disk)
                if let smart = disk.smart {
                    SMARTSection(reading: smart)
                }
            } else if state.okValue != nil {
                Text("디스크 없음")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                StateText(state: state.state)
            }
        }
    }

    private func current(in disks: [DiskReading]) -> DiskReading? {
        disks.first { $0.key == selectedKey } ?? disks.first
    }

    private func picker(_ disks: [DiskReading], current: DiskReading) -> some View {
        Picker("디스크", selection: Binding(get: { current.key }, set: { selectedKey = $0 })) {
            ForEach(disks) { disk in
                Text(disk.name).tag(disk.key)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    /// 활성 시간 (0~100% 고정). 추정 구간은 연한 색 선으로, 추적 구간과 이어서 그려요. (docs/DISK_ACTIVE_TIME.md 4.3)
    private func activeChart(_ disk: DiskReading) -> some View {
        let color = appearance.color(for: .disk)
        return HistoryChart(title: "활성 시간",
                            lines: [ChartLine(metric: .diskActive(disk.id), label: "활성", color: color.color),
                                    ChartLine(metric: .diskActiveEstimate(disk.id), label: "추정",
                                              color: color.secondaryColor)],
                            period: period,
                            scale: .percent,
                            height: 56,
                            emptyState: disk.active.state,
                            note: activeNote(disk),
                            scaleText: ValueFormat.percent) {
            ValueText(reading: disk.active, format: DiskActiveText.format(estimated: disk.activeEstimated),
                      font: .system(size: 12))
        }
    }

    /// 그래프 제목 아래 세부 줄: 추정이면 '추정', 내장 SSD를 디스크 I/O만으로 재면 '디스크 I/O만', 추적 중이면 없음
    private func activeNote(_ disk: DiskReading) -> String? {
        if disk.activeEstimated && disk.active.value != nil {
            return "추정"
        }
        if disk.activeIOOnly {
            return "디스크 I/O만"
        }
        return nil
    }

    /// 읽기·쓰기 속도 (쓰기는 연한 색)
    private func speedChart(_ disk: DiskReading) -> some View {
        let color = appearance.color(for: .disk)
        return HistoryChart(title: "속도",
                            lines: [ChartLine(metric: .diskRead(disk.id), label: "읽기", color: color.color),
                                    ChartLine(metric: .diskWrite(disk.id), label: "쓰기", color: color.secondaryColor)],
                            period: period,
                            scale: .automatic(minimum: 1_000_000),
                            height: 72,
                            emptyState: disk.read.state,
                            scaleText: ValueFormat.rateScale) {
            HStack(spacing: 10) {
                LegendValue(color: color.color, label: "읽기", reading: disk.read, format: ValueFormat.rate)
                LegendValue(color: color.secondaryColor, label: "쓰기", reading: disk.write, format: ValueFormat.rate)
            }
        }
    }

    /// 평균 동시 요청 수
    private func queueChart(_ disk: DiskReading) -> some View {
        HistoryChart(title: "평균 동시 요청",
                     lines: [ChartLine(metric: .diskQueue(disk.id), label: "동시 요청",
                                       color: appearance.color(for: .disk).color)],
                     period: period,
                     scale: .automatic(minimum: 1),
                     height: 48,
                     emptyState: disk.queueDepth.state,
                     scaleText: ValueFormat.compact) {
            ValueText(reading: disk.queueDepth, format: ValueFormat.queueDepth, font: .system(size: 12))
        }
    }
}

/// 응답 시간 · 초당 작업 · 오늘 누적 (열은 읽기·쓰기). 오류·재시도는 있을 때만.
private struct DiskValueTable: View {
    let disk: DiskReading

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 7) {
            GridRow {
                Color.clear
                    .frame(width: 1, height: 1)
                header("읽기")
                header("쓰기")
            }
            Divider()
            GridRow {
                Text("응답 시간")
                latency(disk.readLatency)
                latency(disk.writeLatency)
            }
            Divider()
            GridRow {
                Text("초당 작업")
                ValueText(reading: disk.readOperations, format: ValueFormat.count, font: Self.valueFont)
                ValueText(reading: disk.writeOperations, format: ValueFormat.count, font: Self.valueFont)
            }
            Divider()
            GridRow {
                HStack(spacing: 4) {
                    Text("오늘")
                    if let date = disk.todayDate {
                        Text("· \(ValueFormat.monthDay(date))")
                            .foregroundStyle(.secondary)
                    }
                }
                ValueText(reading: disk.todayRead, format: ValueFormat.byteCount, font: Self.valueFont)
                ValueText(reading: disk.todayWritten, format: ValueFormat.byteCount, font: Self.valueFont)
            }
            if disk.todayHasGap {
                GridRow {
                    Text("누적 일부 누락")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .gridCellColumns(3)
                }
            }
            if disk.readErrors > 0 || disk.writeErrors > 0 {
                Divider()
                GridRow {
                    Label("오류", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(StatusColor.error)
                    count(disk.readErrors)
                    count(disk.writeErrors)
                }
            }
            if disk.readRetries > 0 || disk.writeRetries > 0 {
                Divider()
                GridRow {
                    Text("재시도")
                        .foregroundStyle(StatusColor.error)
                    count(disk.readRetries)
                    count(disk.writeRetries)
                }
            }
        }
        .font(.system(size: 12))
        .padding(10)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private static let valueFont = Font.system(size: 12, weight: .semibold)

    private func header(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .gridColumnAlignment(.trailing)
    }

    /// 작업이 적어 응답 시간을 보이지 않을 때는 '—'
    @ViewBuilder
    private func latency(_ reading: Reading<Double>) -> some View {
        if case .notMeasurable = reading.state {
            Text(ValueFormat.unavailable)
                .font(Self.valueFont)
                .foregroundStyle(.secondary)
        } else {
            ValueText(reading: reading, format: ValueFormat.milliseconds, font: Self.valueFont)
        }
    }

    private func count(_ value: UInt64) -> some View {
        Text("\(value.formatted())회")
            .font(Self.valueFont)
            .monospacedDigit()
            .foregroundStyle(value > 0 ? StatusColor.error : Color.primary)
    }
}

/// SMART (지원하는 디스크만). 문제가 있을 때만 경고 상자를 보여줘요.
private struct SMARTSection: View {
    @Environment(AppearanceSettings.self) private var appearance
    let reading: Reading<SMARTInfo>

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("SMART")
                    .font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 8)
                if reading.okValue != nil, let date = reading.measuredAt {
                    Text("\(ValueFormat.clockMinutes(date)) 측정")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                } else if case .failed = reading.state {
                    Label("읽지 못함 · 다시 시도 중", systemImage: "exclamationmark.triangle")
                        .font(.system(size: 12))
                        .foregroundStyle(StatusColor.error)
                } else {
                    StateText(state: reading.state)
                }
            }
            if let info = reading.okValue {
                if info.hasProblem {
                    problems(info)
                }
                values(info)
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func problems(_ info: SMARTInfo) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if !info.warningTexts.isEmpty {
                problemRow("위험 경고", info.warningTexts.joined(separator: ", "))
            }
            if info.mediaErrors > 0 {
                problemRow("매체 오류", "\(info.mediaErrors.formatted())회")
            }
            if info.errorLogEntries > 0 {
                problemRow("오류 기록", "\(info.errorLogEntries.formatted())건")
            }
            let hotMinutes = UInt64(info.warningTemperatureMinutes) + UInt64(info.criticalTemperatureMinutes)
            if hotMinutes > 0 {
                problemRow("고온 시간", "\(hotMinutes.formatted())분")
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(StatusColor.error)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(StatusColor.error.opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func problemRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
                .fontWeight(.semibold)
            Spacer(minLength: 8)
            Text(value)
                .monospacedDigit()
        }
    }

    private func values(_ info: SMARTInfo) -> some View {
        let spareLow = info.availableSpare < info.spareThreshold
        return Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
            GridRow {
                barValue("수명 사용", percent: info.percentageUsed, warning: false)
                barValue("예비 공간", percent: info.availableSpare, warning: spareLow)
            }
            GridRow {
                pair("총 쓰기", ValueFormat.byteCount(info.totalWritten))
                pair("총 읽기", ValueFormat.byteCount(info.totalRead))
            }
            GridRow {
                pair("사용 시간", "\(info.powerOnHours.formatted())시간")
                pair("전원 켠 횟수", "\(info.powerCycles.formatted())회")
            }
            GridRow {
                pair("비정상 종료", "\(info.unsafeShutdowns.formatted())회")
                Color.clear
                    .frame(height: 1)
            }
        }
        .font(.system(size: 12))
    }

    private func barValue(_ title: String, percent: Int, warning: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            pair(title, "\(percent)%", warning: warning)
            UsageBar(fraction: min(max(Double(percent) / 100, 0), 1),
                     color: warning ? StatusColor.error : appearance.color(for: .disk).color,
                     height: 4)
        }
    }

    private func pair(_ title: String, _ value: String, warning: Bool = false) -> some View {
        HStack {
            Text(title)
                .foregroundStyle(warning ? StatusColor.error : Color.secondary)
            Spacer(minLength: 8)
            Text(value)
                .fontWeight(.semibold)
                .monospacedDigit()
                .foregroundStyle(warning ? StatusColor.error : Color.primary)
        }
        .frame(maxWidth: .infinity)
    }
}
