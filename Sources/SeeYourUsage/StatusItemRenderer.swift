import AppKit
import SeeYourUsageCore

enum StatusItemRenderer {
    static let size = NSSize(width: 100, height: 23)
    static func size(for state: UsageViewState) -> NSSize {
        guard state.provider == .llmCenter else {
            let font = NSFont.monospacedDigitSystemFont(ofSize: 8.1, weight: .medium)
            let width = displayedWindows(from: state.snapshot).map { row in
                let text = row.window.map { UsageFormatting.menuResetText(for: $0) } ?? "--"
                return text.size(withAttributes: [.font: font]).width
            }.max() ?? 0
            return NSSize(width: 68 + ceil(width), height: 23)
        }
        if state.menuPrompt != nil { return NSSize(width: 58, height: 23) }
        let values = [state.quota.map { QuotaFormatting.amount($0.monthlyRemaining, compact: true) } ?? "待更新",
                      state.quota.map { QuotaFormatting.today($0.todayUsed, compact: true) } ?? "待更新"]
        let font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
        let width = values.map { $0.size(withAttributes: [.font: font]).width }.max() ?? 36
        return NSSize(width: ceil(width) + 4, height: 23)
    }

    static func image(for state: UsageViewState, appearance: NSAppearance?) -> NSImage {
        if state.provider == .llmCenter { return quotaImage(for: state) }
        let size = size(for: state)
        let windows = displayedWindows(from: state.snapshot)
        let rowPositions: [CGFloat] = windows.count > 1 ? [12.6, 2.2] : [7.4]

        let image = NSImage(size: size, flipped: false) { rect in
            drawBackgroundIfPaused(in: rect, isPaused: state.isPaused)
            for (index, row) in windows.enumerated() {
                drawRow(
                    window: row.window,
                    resetText: row.window.map { UsageFormatting.menuResetText(for: $0) } ?? "--",
                    y: rowPositions[index],
                    isDimmed: state.isPaused,
                    totalWidth: size.width
                )
            }

            return true
        }
        image.isTemplate = false
        return image
    }

    private static func quotaImage(for state: UsageViewState) -> NSImage {
        let size = size(for: state)
        let quota = state.quota
        let stale = state.errorMessage != nil || state.isPaused
        let image = NSImage(size: size, flipped: false) { _ in
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            if let prompt = state.menuPrompt {
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 10, weight: .medium),
                    .foregroundColor: NSColor.labelColor,
                    .paragraphStyle: paragraph
                ]
                prompt.0.draw(in: NSRect(x: 0, y: 11, width: size.width, height: 12), withAttributes: attributes)
                prompt.1.draw(in: NSRect(x: 0, y: 0, width: size.width, height: 12), withAttributes: attributes)
                return true
            }
            let values = [quota.flatMap { $0.isCurrentMonth() ? QuotaFormatting.amount($0.monthlyRemaining, compact: true) : nil },
                          quota.flatMap { $0.isCurrentDay() ? QuotaFormatting.today($0.todayUsed, compact: true) : nil }]
            for index in 0..<2 {
                let color: NSColor = index == 0 && quota != nil && !stale
                    ? UsageColors.accent(forMonthlyRemaining: quota!.monthlyRemaining) : .labelColor
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold),
                    .foregroundColor: color.withAlphaComponent(stale ? 0.5 : 0.95),
                    .paragraphStyle: paragraph
                ]
                (values[index] ?? "待更新").draw(in: NSRect(x: 2, y: index == 0 ? 11 : 0, width: size.width - 4, height: 12), withAttributes: attributes)
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    private static func displayedWindows(from snapshot: UsageSnapshot?) -> [(kind: UsageWindow.Kind, window: UsageWindow?)] {
        guard let snapshot else {
            return [(.sevenDay, nil)]
        }

        let windows = UsageWindow.Kind.allCases.compactMap { kind -> (UsageWindow.Kind, UsageWindow)? in
            snapshot.window(kind: kind).map { (kind, $0) }
        }
        return windows.isEmpty ? [(.sevenDay, nil)] : windows
    }

    private static func drawBackgroundIfPaused(in rect: NSRect, isPaused: Bool) {
        guard isPaused else { return }
        let path = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1.5), xRadius: 7, yRadius: 7)
        NSColor.labelColor.withAlphaComponent(0.08).setFill()
        path.fill()
    }

    private static func drawRow(window: UsageWindow?, resetText: String, y: CGFloat, isDimmed: Bool, totalWidth: CGFloat) {
        let alpha: CGFloat = isDimmed ? 0.45 : 1

        drawCells(
            window: window,
            rect: NSRect(x: 1, y: y + 1.2, width: 62, height: 5.4),
            alpha: alpha
        )

        let timeRect = NSRect(x: 67, y: y - 0.4, width: totalWidth - 68, height: 10)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .left
        let timeAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 8.1, weight: .medium),
            .foregroundColor: NSColor.labelColor.withAlphaComponent(0.86 * alpha),
            .paragraphStyle: paragraph
        ]
        resetText.draw(in: timeRect, withAttributes: timeAttributes)
    }

    private static func drawCells(window: UsageWindow?, rect: NSRect, alpha: CGFloat) {
        let cellCount = 12
        let gap: CGFloat = 1.3
        let cellWidth = (rect.width - gap * CGFloat(cellCount - 1)) / CGFloat(cellCount)
        let remainingPercent = window?.remainingPercent ?? 0
        let litCells = Int(round((remainingPercent / 100) * Double(cellCount)))
        let remainingColor = UsageColors.accent(forRemainingPercent: remainingPercent).withAlphaComponent(0.92 * alpha)
        let usedColor = NSColor.labelColor.withAlphaComponent(0.17 * alpha)

        for index in 0..<cellCount {
            let x = rect.minX + CGFloat(index) * (cellWidth + gap)
            let cellRect = NSRect(x: x, y: rect.minY, width: cellWidth, height: rect.height)
            let path = NSBezierPath(roundedRect: cellRect, xRadius: rect.height / 2, yRadius: rect.height / 2)
            (index < litCells ? remainingColor : usedColor).setFill()
            path.fill()
        }
    }

}
