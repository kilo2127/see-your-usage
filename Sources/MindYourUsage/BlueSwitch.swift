import AppKit

final class BlueSwitch: NSButton {
    override var intrinsicContentSize: NSSize {
        NSSize(width: 38, height: 22)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        title = ""
        isBordered = false
        setButtonType(.toggle)
        focusRingType = .none
        toolTip = "Open at Login"
        setAccessibilityRole(.checkBox)
        setAccessibilityLabel("Open at Login")
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var state: NSControl.StateValue {
        didSet { needsDisplay = true }
    }

    override var isHighlighted: Bool {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 1, dy: 2)
        let isOn = state == .on
        let trackColor = isOn
            ? NSColor.systemBlue
            : NSColor.labelColor.withAlphaComponent(0.18)
        let knobColor = NSColor.white
        let pressScale: CGFloat = isHighlighted ? 0.96 : 1

        let track = NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
        trackColor.withAlphaComponent(isHighlighted ? 0.82 : 1).setFill()
        track.fill()

        let knobSize = rect.height - 4
        let knobX = isOn ? rect.maxX - knobSize - 2 : rect.minX + 2
        let knobRect = NSRect(
            x: knobX + knobSize * (1 - pressScale) / 2,
            y: rect.midY - knobSize * pressScale / 2,
            width: knobSize * pressScale,
            height: knobSize * pressScale
        )

        NSGraphicsContext.current?.cgContext.setShadow(
            offset: CGSize(width: 0, height: -0.5),
            blur: 2,
            color: NSColor.black.withAlphaComponent(0.22).cgColor
        )
        knobColor.setFill()
        NSBezierPath(ovalIn: knobRect).fill()
        NSGraphicsContext.current?.cgContext.setShadow(offset: .zero, blur: 0, color: nil)
    }
}
