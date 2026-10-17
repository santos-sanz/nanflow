import AppKit
import NanflowCore

/// Floating non-activating bubble that shows recording state near the mouse cursor.
final class BubblePanel: NSPanel {
    let containerView = BubbleView()

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 148, height: 44),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovable = false
        hidesOnDeactivate = false
        hasShadow = true
        contentView = containerView
    }

    func showRecording(near point: NSPoint) {
        let size = containerView.fittingSize
        setContentSize(size)
        let screen = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let margin: CGFloat = 12
        var origin = NSPoint(x: point.x - size.width / 2, y: point.y - size.height - margin)
        origin.x = min(max(origin.x, screen.minX + 8), screen.maxX - size.width - 8)
        origin.y = min(max(origin.y, screen.minY + 8), screen.maxY - size.height - 8)
        setFrameOrigin(origin)
        containerView.mode = .recording
        orderFrontRegardless()
    }

    func showProcessing() {
        containerView.mode = .processing
    }

    func hide() {
        orderOut(nil)
    }
}

final class BubbleView: NSView {
    enum Mode { case recording, processing }
    var mode: Mode = .recording { didSet { needsDisplay = true } }

    private var timer: Timer?
    private var pulse: CGFloat = 0
    private var level: Float = 0

    override var isFlipped: Bool { true }

    override var fittingSize: NSSize {
        NSSize(width: 148, height: 44)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                guard let self else { return }
                pulse += 0.05
                if let panel = window as? BubblePanel, panel.containerView === self {
                    level = DictationBridge.sharedLevel()
                }
                needsDisplay = true
            }
        } else {
            timer?.invalidate()
            timer = nil
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let bg = NSBezierPath(roundedRect: bounds, xRadius: 22, yRadius: 22)
        NSColor(calibratedWhite: 0.08, alpha: 0.92).setFill()
        bg.fill()

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.white,
        ]

        let dotRect = NSRect(x: 18, y: bounds.midY - 6, width: 12, height: 12)
        switch mode {
        case .recording:
            let alpha = 0.55 + 0.45 * abs(sin(pulse * 3))
            NSColor.systemRed.withAlphaComponent(alpha).setFill()
            NSBezierPath(ovalIn: dotRect).fill()

            let text = "Grabando…"
            let size = text.size(withAttributes: attrs)
            text.draw(at: NSPoint(x: dotRect.maxX + 10, y: bounds.midY - size.height / 2), withAttributes: attrs)

            // level meter
            let meterRect = NSRect(x: dotRect.maxX + 10, y: bounds.midY + 6, width: bounds.width - dotRect.maxX - 24, height: 3)
            NSColor.white.withAlphaComponent(0.15).setFill()
            NSBezierPath(roundedRect: meterRect, xRadius: 1.5, yRadius: 1.5).fill()
            NSColor.systemGreen.setFill()
            let w = meterRect.width * CGFloat(min(1, level))
            if w > 1 {
                NSBezierPath(roundedRect: NSRect(x: meterRect.minX, y: meterRect.minY, width: w, height: meterRect.height), xRadius: 1.5, yRadius: 1.5).fill()
            }
        case .processing:
            let alpha = 0.4 + 0.6 * abs(sin(pulse * 5))
            NSColor.systemBlue.withAlphaComponent(alpha).setFill()
            NSBezierPath(ovalIn: dotRect).fill()
            let text = "Transcribiendo…"
            let size = text.size(withAttributes: attrs)
            text.draw(at: NSPoint(x: dotRect.maxX + 10, y: bounds.midY - size.height / 2), withAttributes: attrs)
        }
    }
}

/// Small bridge so the bubble can read the engine's mic level without strong references.
enum DictationBridge {
    static weak var engine: DictationEngine?
    static func sharedLevel() -> Float { engine?.level ?? 0 }
}
