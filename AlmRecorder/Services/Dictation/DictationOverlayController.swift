import AppKit

@MainActor
final class DictationOverlayController {
    private let panel: NSPanel
    private let statusLabel = NSTextField(labelWithString: "")
    private let transcriptLabel = NSTextField(wrappingLabelWithString: "")

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 104),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.ignoresMouseEvents = true

        let effect = NSVisualEffectView(frame: panel.contentView!.bounds)
        effect.autoresizingMask = [.width, .height]
        effect.material = .hudWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 18

        statusLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        statusLabel.textColor = .secondaryLabelColor
        transcriptLabel.font = .systemFont(ofSize: 17, weight: .medium)
        transcriptLabel.maximumNumberOfLines = 2
        transcriptLabel.lineBreakMode = .byTruncatingHead

        let stack = NSStackView(views: [statusLabel, transcriptLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: effect.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: effect.bottomAnchor, constant: -16)
        ])
        panel.contentView = effect
    }

    func show(status: String, text: String = "") {
        update(status: status, text: text)
        let visibleFrame = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? .zero
        let frame = panel.frame
        panel.setFrameOrigin(
            NSPoint(
                x: visibleFrame.midX - frame.width / 2,
                y: visibleFrame.minY + 72
            )
        )
        panel.alphaValue = 1
        panel.orderFrontRegardless()
    }

    func update(status: String, text: String) {
        statusLabel.stringValue = status
        transcriptLabel.stringValue = text.isEmpty ? "…" : text
    }

    func hide() {
        panel.orderOut(nil)
    }
}
