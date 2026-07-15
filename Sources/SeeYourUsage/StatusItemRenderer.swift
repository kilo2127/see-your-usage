import AppKit
import SeeYourUsageCore

enum StatusItemRenderer {
    static let size = NSSize(width: 153, height: 23)

    static func image(for state: UsageViewState, appearance: NSAppearance?) -> NSImage {
        let windows = displayedWindows(from: state.snapshot)
        let rowPositions: [CGFloat] = windows.count > 1 ? [12.6, 2.2] : [7.4]

        let image = NSImage(size: size, flipped: false) { rect in
            drawBackgroundIfPaused(in: rect, isPaused: state.isPaused)
            for (index, row) in windows.enumerated() {
                drawRow(
                    label: row.kind.rawValue,
                    window: row.window,
                    resetText: row.window.map { UsageFormatting.menuResetText(for: $0) } ?? "--",
                    y: rowPositions[index],
                    isDimmed: state.isPaused
                )
            }

            if state.isRefreshing {
                drawRefreshDot()
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

    private static func drawRow(label: String, window: UsageWindow?, resetText: String, y: CGFloat, isDimmed: Bool) {
        let alpha: CGFloat = isDimmed ? 0.45 : 1
        let labelAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 8.4, weight: .semibold),
            .foregroundColor: NSColor.labelColor.withAlphaComponent(0.86 * alpha)
        ]
        label.draw(at: NSPoint(x: 0.5, y: y - 0.2), withAttributes: labelAttributes)

        drawCells(
            window: window,
            rect: NSRect(x: 23, y: y + 1.2, width: 77, height: 5.4),
            alpha: alpha
        )

        let timeRect = NSRect(x: 107, y: y - 0.4, width: 46, height: 10)
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
        let gap: CGFloat = 1.7
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

    private static func drawRefreshDot() {
        let rect = NSRect(x: size.width - 4.5, y: size.height - 5.8, width: 3.2, height: 3.2)
        let path = NSBezierPath(ovalIn: rect)
        NSColor.controlAccentColor.withAlphaComponent(0.9).setFill()
        path.fill()
    }
}
