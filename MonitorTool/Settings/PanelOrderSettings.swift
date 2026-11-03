import CoreTransferable
import Foundation
import SwiftUI

/// 설정 창 '모양 > 항목 순서': 패널 카드 덩어리 순서와 맨 위 카드 안 열 순서를 끌어서 바꿔요. (2026-11-03 사용자 요청)
/// 줄(또는 칩)을 다른 줄 위에 놓으면 그 자리로 옮겨져요. 패널에 바로 반영돼요.
struct PanelOrderBox: View {
    @Environment(AppearanceSettings.self) private var appearance
    /// 지금 끌어 온 것이 놓일 줄·칩 (강조 표시)
    @State private var targetedSection: PanelSection?
    @State private var targetedColumn: MonitorItem?

    var body: some View {
        VStack(spacing: 0) {
            ForEach(appearance.sectionOrder) { section in
                if section != appearance.sectionOrder.first {
                    Divider()
                }
                sectionRow(section)
            }
            Divider()
            columnRow
        }
    }

    // MARK: 카드 덩어리

    private func sectionRow(_ section: PanelSection) -> some View {
        let items = section == .processor ? appearance.processorOrder : section.items
        let isTargeted = targetedSection == section
        return HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            Text(section.title)
                .font(.system(size: 13))
            Spacer(minLength: 8)
            HStack(spacing: 4) {
                ForEach(items) { item in
                    Circle()
                        .fill(appearance.color(for: item).color)
                        .frame(width: 8, height: 8)
                }
            }
            .accessibilityHidden(true)
        }
        .padding(.horizontal, 12)
        .frame(height: 32)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if isTargeted {
                Color.accentColor.opacity(0.12)
            }
        }
        .contentShape(Rectangle())
        .draggable(Self.sectionPayload(section)) {
            DragLabel(title: section.title)
        }
        .dropDestination(for: String.self) { values, _ in
            guard let moved = values.first.flatMap(Self.section(from:)) else { return false }
            withAnimation(.smooth(duration: 0.25)) {
                appearance.moveSection(moved, onto: section)
            }
            return true
        } isTargeted: { targeted in
            if targeted {
                targetedSection = section
            } else if targetedSection == section {
                targetedSection = nil
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: Text("위로 옮기기")) {
            appearance.shiftSection(section, by: -1)
        }
        .accessibilityAction(named: Text("아래로 옮기기")) {
            appearance.shiftSection(section, by: 1)
        }
    }

    // MARK: 맨 위 카드 안 열

    private var columnRow: some View {
        HStack(spacing: 10) {
            Text("맨 위 카드 열")
                .font(.system(size: 13))
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                ForEach(appearance.processorOrder) { item in
                    columnChip(item)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func columnChip(_ item: MonitorItem) -> some View {
        let isTargeted = targetedColumn == item
        return HStack(spacing: 5) {
            Circle()
                .fill(appearance.color(for: item).color)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            Text(item.title)
                .font(.system(size: 12, weight: .medium))
        }
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(Color.primary.opacity(isTargeted ? 0.14 : 0.06), in: Capsule())
        .overlay {
            if isTargeted {
                Capsule()
                    .strokeBorder(Color.accentColor.opacity(0.5), lineWidth: 1)
            }
        }
        .contentShape(Capsule())
        .draggable(Self.columnPayload(item)) {
            DragLabel(title: item.title)
        }
        .dropDestination(for: String.self) { values, _ in
            guard let moved = values.first.flatMap(Self.column(from:)) else { return false }
            withAnimation(.smooth(duration: 0.25)) {
                appearance.moveProcessorItem(moved, onto: item)
            }
            return true
        } isTargeted: { targeted in
            if targeted {
                targetedColumn = item
            } else if targetedColumn == item {
                targetedColumn = nil
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: Text("왼쪽으로 옮기기")) {
            appearance.shiftProcessorItem(item, by: -1)
        }
        .accessibilityAction(named: Text("오른쪽으로 옮기기")) {
            appearance.shiftProcessorItem(item, by: 1)
        }
    }

    // MARK: 끌어 옮기는 값
    // 다른 앱에서 끌어 온 글이나 줄·칩이 섞이지 않게 앞에 이름표를 붙여요.

    private static let sectionPrefix = "MonitorTool.panelSection:"
    private static let columnPrefix = "MonitorTool.panelColumn:"

    private static func sectionPayload(_ section: PanelSection) -> String {
        sectionPrefix + section.rawValue
    }

    private static func columnPayload(_ item: MonitorItem) -> String {
        columnPrefix + item.rawValue
    }

    private static func section(from payload: String) -> PanelSection? {
        guard payload.hasPrefix(sectionPrefix) else { return nil }
        return PanelSection(rawValue: String(payload.dropFirst(sectionPrefix.count)))
    }

    private static func column(from payload: String) -> MonitorItem? {
        guard payload.hasPrefix(columnPrefix) else { return nil }
        let item = MonitorItem(rawValue: String(payload.dropFirst(columnPrefix.count)))
        return item.flatMap { PanelSection.processorItems.contains($0) ? $0 : nil }
    }
}

/// 끄는 동안 마우스를 따라다니는 이름표
private struct DragLabel: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.regularMaterial, in: Capsule())
    }
}
