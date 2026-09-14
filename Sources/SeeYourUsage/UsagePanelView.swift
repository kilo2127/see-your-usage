import AppKit
import SeeYourUsageCore

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
    var quotaAmount: String? { didSet { needsDisplay = true } }
    var quotaCaption = "" { didSet { needsDisplay = true } }
    var quotaFooter = "" { didSet { needsDisplay = true } }
    var monthlyRemaining: Decimal? { didSet { needsDisplay = true } }
    var quotaPercent: Double? { didSet { needsDisplay = true } }
    var isQuota = false { didSet { needsDisplay = true } }
    var isToday = false { didSet { needsDisplay = true } }

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
        if isQuota { drawQuotaText(in: rect); return }
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
        if isQuota && isToday { return }
        let barRect = NSRect(x: 14, y: isQuota ? 32 : 16, width: rect.width - 28, height: isQuota ? 9 : 12)
        let cellCount = 18
        let gap: CGFloat = 3
        let cellWidth = (barRect.width - gap * CGFloat(cellCount - 1)) / CGFloat(cellCount)
        let remainingPercent = isQuota ? (quotaPercent ?? 0) : (usageWindow?.remainingPercent ?? 0)
        let litCells = Int(round((remainingPercent / 100) * Double(cellCount)))
        let liveColor = isQuota ? monthlyRemaining.map { UsageColors.accent(forMonthlyRemaining: $0) } ?? .secondaryLabelColor : UsageColors.accent(forRemainingPercent: remainingPercent)
        let usedColor = NSColor.labelColor.withAlphaComponent(0.13)

        for index in 0..<cellCount {
            let x = barRect.minX + CGFloat(index) * (cellWidth + gap)
            let rect = NSRect(x: x, y: barRect.minY, width: cellWidth, height: barRect.height)
            let path = NSBezierPath(roundedRect: rect, xRadius: 4.5, yRadius: 4.5)
            (index < litCells ? liveColor : usedColor).setFill()
            path.fill()
        }
    }

    private func drawQuotaText(in rect: NSRect) {
        title.draw(at: NSPoint(x: 14, y: rect.height - 31), withAttributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.labelColor])
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .right
        let color = isToday ? NSColor.labelColor : monthlyRemaining.map { UsageColors.accent(forMonthlyRemaining: $0) } ?? .labelColor
        let amount = quotaAmount ?? "—"
        var font = NSFont.monospacedDigitSystemFont(ofSize: 24, weight: .semibold)
        while amount.size(withAttributes: [.font: font]).width > rect.width - 99 && font.pointSize > 14 {
            font = .monospacedDigitSystemFont(ofSize: font.pointSize - 1, weight: .semibold)
        }
        amount.draw(in: NSRect(x: 85, y: rect.height - 37, width: rect.width - 99, height: 31), withAttributes: [
            .font: font,
            .foregroundColor: color, .paragraphStyle: paragraph])
        let captionParagraph = NSMutableParagraphStyle()
        captionParagraph.lineBreakMode = .byTruncatingMiddle
        let captionStyle: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: captionParagraph]
        quotaCaption.draw(in: NSRect(x: 14, y: rect.height - 55, width: rect.width - 28, height: 15), withAttributes: captionStyle)
        if !isToday { quotaFooter.draw(at: NSPoint(x: 14, y: 12), withAttributes: captionStyle) }
    }

}
