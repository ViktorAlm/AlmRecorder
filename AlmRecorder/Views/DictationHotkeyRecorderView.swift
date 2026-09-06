import AppKit
import SwiftUI

struct DictationHotkeyRecorderSheet: View {
    let onCapture: (DictationHotkeyBinding) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "keyboard")
                .font(.system(size: 34))
                .foregroundStyle(.tint)

            Text("Record Dictation Shortcut")
                .font(.title2.weight(.semibold))

            Text("Press a key together with Command, Option, Control, Shift, or Fn.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            DictationHotkeyCaptureView(
                onCapture: onCapture,
                onCancel: onCancel
            )
            .frame(height: 58)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.accentColor, lineWidth: 2)
            )

            Text("Press Escape to cancel. For Fn by itself, choose the Willow-style preset.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(28)
        .frame(width: 430)
    }
}

private struct DictationHotkeyCaptureView: NSViewRepresentable {
    let onCapture: (DictationHotkeyBinding) -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> CaptureView {
        CaptureView(onCapture: onCapture, onCancel: onCancel)
    }

    func updateNSView(_ view: CaptureView, context: Context) {
        view.onCapture = onCapture
        view.onCancel = onCancel
    }

    final class CaptureView: NSView {
        var onCapture: (DictationHotkeyBinding) -> Void
        var onCancel: () -> Void

        init(
            onCapture: @escaping (DictationHotkeyBinding) -> Void,
            onCancel: @escaping () -> Void
        ) {
            self.onCapture = onCapture
            self.onCancel = onCancel
            super.init(frame: .zero)
            wantsLayer = true
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override var acceptsFirstResponder: Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.window?.makeFirstResponder(self)
            }
        }

        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            let text = "Press shortcut now…"
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 15, weight: .medium),
                .foregroundColor: NSColor.secondaryLabelColor
            ]
            let size = text.size(withAttributes: attributes)
            text.draw(
                at: NSPoint(
                    x: bounds.midX - size.width / 2,
                    y: bounds.midY - size.height / 2
                ),
                withAttributes: attributes
            )
        }

        override func keyDown(with event: NSEvent) {
            guard !event.isARepeat else { return }
            if event.keyCode == 53 {
                onCancel()
                return
            }

            let relevant: NSEvent.ModifierFlags = [
                .control, .option, .shift, .command, .function
            ]
            let modifiers = event.modifierFlags.intersection(relevant)
            guard !modifiers.isEmpty else {
                NSSound.beep()
                return
            }

            onCapture(
                DictationHotkeyBinding(
                    keyCode: event.keyCode,
                    modifiers: modifiers,
                    keyLabel: Self.label(for: event)
                )
            )
        }

        private static func label(for event: NSEvent) -> String {
            switch event.keyCode {
            case 36: return "Return"
            case 48: return "Tab"
            case 49: return "Space"
            case 51: return "Delete"
            case 117: return "Forward Delete"
            case 123: return "←"
            case 124: return "→"
            case 125: return "↓"
            case 126: return "↑"
            default:
                let text = event.charactersIgnoringModifiers?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .uppercased()
                return text?.isEmpty == false ? text! : "Key \(event.keyCode)"
            }
        }
    }
}
