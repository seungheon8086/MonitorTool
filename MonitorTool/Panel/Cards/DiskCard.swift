import Foundation
import SwiftUI

/// 디스크 카드 (화면 시안 '디스크 B안'·'활성 시간 · 디스크 카드', docs/DISK_IO.md · docs/DISK_ACTIVE_TIME.md)
/// 물리 디스크마다 한 줄: 이름 · 읽기 · 쓰기 · 활성(숫자 + 짧은 막대). 추정이면 숫자 앞에 ≈, 막대는 연한 색
struct DiskCard: View {
    @Environment(MonitorStore.self) private var store
    @Environment(AppearanceSettings.self) private var appearance
    @Binding var expanded: Set<MonitorItem>

    var body: some View {
        let state = store.snapshot.disk.disks
        SectionCard(item: .disk, expanded: $expanded) {
            EmptyView()
        } content: {
            if let disks = state.okValue {
                if disks.isEmpty {
                    Text("디스크 없음")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                } else {
                    table(disks)
                }
            } else {
                StateText(state: state.state)
            }
        }
    }

    private func table(_ disks: [DiskReading]) -> some View {
        let color = appearance.color(for: .disk)
        return Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
            GridRow {
                Color.clear
                    .frame(width: 1, height: 1)
                header("읽기")
                header("쓰기")
                header("활성")
                Color.clear
                    .frame(width: 1, height: 1)
            }
            ForEach(disks) { disk in
                GridRow(alignment: .firstTextBaseline) {
                    Text(disk.name)
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    ValueText(reading: disk.read, format: ValueFormat.rate)
                        .lineLimit(1)
                        .gridColumnAlignment(.trailing)
                    ValueText(reading: disk.write, format: ValueFormat.rate)
                        .lineLimit(1)
                        .gridColumnAlignment(.trailing)
                    activeText(disk)
                        .gridColumnAlignment(.trailing)
                    DiskActiveBar(reading: disk.active,
                                  fill: disk.activeEstimated ? color.secondaryColor : color.color)
                }
            }
        }
    }

    private func header(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .gridColumnAlignment(.trailing)
    }

    /// 활성 시간은 준비 중이면 '—'로 짧게 (좁은 칸이라)
    @ViewBuilder
    private func activeText(_ disk: DiskReading) -> some View {
        if disk.active.state == .preparing {
            Text(ValueFormat.unavailable)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        } else {
            ValueText(reading: disk.active, format: DiskActiveText.format(estimated: disk.activeEstimated))
        }
    }
}

/// 활성 시간 글이에요. 추정이면 숫자 앞에 ≈를 붙여요. (카드와 펼친 상세가 같이 써요)
enum DiskActiveText {
    static func format(estimated: Bool) -> (Double) -> String {
        { value in (estimated ? "≈" : "") + ValueFormat.percent(value) }
    }
}

/// 활성 시간 짧은 막대 (0~100%, 카드 줄 오른쪽 끝). 오래된 값이면 흐리게 (docs/DISK_ACTIVE_TIME.md 4.3)
struct DiskActiveBar: View {
    let reading: Reading<Double>
    /// 채움 색 (추적이면 디스크 색, 추정이면 두 번째 계열 색)
    let fill: Color

    private static let width: CGFloat = 44
    private static let height: CGFloat = 6

    var body: some View {
        let shown = Self.shown(reading)
        let fraction = shown.map { min(max($0.value / 100, 0), 1) } ?? 0
        RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(Color.primary.opacity(0.08))
            .frame(width: Self.width, height: Self.height)
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(fill)
                    .frame(width: Self.width * fraction)
            }
            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
            .opacity(shown?.stale == true ? 0.45 : 1)
            // 숫자 줄의 가운데쯤에 오게 해요. (15pt 숫자의 기준선보다 5pt 위가 막대 가운데)
            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 5 }
            .accessibilityHidden(true)
    }

    /// 막대에 쓸 값: 정상 값, 또는 오래된 값(흐리게). 다른 상태면 빈 막대예요.
    private static func shown(_ reading: Reading<Double>) -> (value: Double, stale: Bool)? {
        if let value = reading.okValue {
            return (value, false)
        }
        if case .stale = reading.state, let value = reading.value {
            return (value, true)
        }
        return nil
    }
}
