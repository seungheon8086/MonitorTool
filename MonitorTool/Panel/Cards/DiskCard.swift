import Foundation
import SwiftUI

/// 디스크 카드 (화면 시안 '디스크 B안', docs/DISK_IO.md)
/// 물리 디스크마다 한 줄: 이름 · 읽기 · 쓰기 · 동시(평균 동시 요청 수)
struct DiskCard: View {
    @Environment(MonitorStore.self) private var store
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
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
            GridRow {
                Color.clear
                    .frame(width: 1, height: 1)
                header("읽기")
                header("쓰기")
                header("동시")
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
                    queueText(disk.queueDepth)
                        .gridColumnAlignment(.trailing)
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

    /// 동시 요청은 준비 중이면 '—'로 짧게 (좁은 칸이라)
    @ViewBuilder
    private func queueText(_ reading: Reading<Double>) -> some View {
        if reading.state == .preparing {
            Text(ValueFormat.unavailable)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        } else {
            ValueText(reading: reading, format: ValueFormat.queueDepth)
        }
    }
}
