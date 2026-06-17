import AppKit
import MindYourUsageCore

final class UsagePanelView: NSView {
    var title: String = "" {
        didSet { needsDisplay = true }
    }

    var subtitle: String = "" {
        didSet { needsDisplay = true }
    }

    var usageWindow: UsageWindow? {
        didSet { needsDisplay = true }
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 320, height: 86)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.08
        layer?.shadowRadius = 12
        layer?.shadowOffset = NSSize(width: 0, height: -3)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let bounds = bounds.insetBy(dx: 0, dy: 0)
        drawPanelBackground(in: bounds)
        drawText(in: bounds)
        drawBar(in: bounds)
    }

    private func drawPanelBackground(in rect: NSRect) {
        let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
        NSColor.windowBackgroundColor.withAlphaComponent(0.18).setFill()
        path.fill()

        let highlight = NSGradient(colors: [
            NSColor.white.withAlphaComponent(0.34),
            NSColor.white.withAlphaComponent(0.08)
        ])
        highlight?.draw(in: path, angle: -90)

        NSColor.white.withAlphaComponent(0.38).setStroke()
        path.lineWidth = 0.8
        path.stroke()

        let inner = NSBezierPath(roundedRect: rect.insetBy(dx: 1.5, dy: 1.5), xRadius: 8.5, yRadius: 8.5)
        NSColor.separatorColor.withAlphaComponent(0.18).setStroke()
        inner.lineWidth = 0.5
        inner.stroke()
    }

    private func drawText(in rect: NSRect) {
        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.labelColor
        ]
        title.draw(at: NSPoint(x: 14, y: rect.height - 27), withAttributes: titleAttributes)

        let percentText = usageWindow.map { UsageFormatting.percent($0.remainingPercent) } ?? "--"
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .right
        let percentAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 17, weight: .semibold),
            .foregroundColor: UsageColors.accent(forRemainingPercent: usageWindow?.remainingPercent ?? 0),
            .paragraphStyle: paragraph
        ]
        percentText.draw(
            in: NSRect(x: rect.width - 178, y: rect.height - 31, width: 164, height: 24),
            withAttributes: percentAttributes
        )

        let resetText = usageWindow.map { UsageFormatting.dashboardResetText(for: $0) } ?? "Waiting for Codex"
        let caption = subtitle.isEmpty ? resetText : "\(subtitle) · \(resetText)"
        let captionAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        caption.draw(at: NSPoint(x: 14, y: rect.height - 47), withAttributes: captionAttributes)
    }

    private func drawBar(in rect: NSRect) {
        let barRect = NSRect(x: 14, y: 16, width: rect.width - 28, height: 12)
        let cellCount = 18
        let gap: CGFloat = 3
        let cellWidth = (barRect.width - gap * CGFloat(cellCount - 1)) / CGFloat(cellCount)
        let remainingPercent = usageWindow?.remainingPercent ?? 0
        let litCells = Int(round((remainingPercent / 100) * Double(cellCount)))
        let liveColor = UsageColors.accent(forRemainingPercent: remainingPercent)
        let usedColor = NSColor.labelColor.withAlphaComponent(0.13)

        for index in 0..<cellCount {
            let x = barRect.minX + CGFloat(index) * (cellWidth + gap)
            let rect = NSRect(x: x, y: barRect.minY, width: cellWidth, height: barRect.height)
            let path = NSBezierPath(roundedRect: rect, xRadius: 4.5, yRadius: 4.5)
            (index < litCells ? liveColor : usedColor).setFill()
            path.fill()
        }
    }

}
