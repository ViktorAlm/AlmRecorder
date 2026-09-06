import AppKit

/// Hold Control-Option-Space to dictate. A conventional chord is used for the first release because
/// macOS does not expose Fn-only key-up events consistently across keyboard types.
@MainActor
final class GlobalDictationHotkey {
    private static let relevantModifiers: NSEvent.ModifierFlags = [
        .control, .option, .shift, .command, .function
    ]

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var keyIsDown = false
    private let binding: DictationHotkeyBinding
    private let onPress: () -> Void
    private let onRelease: () -> Void

    init(
        binding: DictationHotkeyBinding,
        onPress: @escaping () -> Void,
        onRelease: @escaping () -> Void
    ) {
        self.binding = binding
        self.onPress = onPress
        self.onRelease = onRelease
    }

    func start() {
        guard globalMonitor == nil, localMonitor == nil else { return }
        let mask: NSEvent.EventTypeMask = [.keyDown, .keyUp, .flagsChanged]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            Task { @MainActor in _ = self?.handle(event) }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handle(event) == true ? nil : event
        }
    }

    func stop() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
        keyIsDown = false
    }

    @discardableResult
    private func handle(_ event: NSEvent) -> Bool {
        if binding.isFunctionOnly {
            return handleFunctionKey(event)
        }
        guard let keyCode = binding.keyCode, event.keyCode == keyCode else {
            return false
        }

        // Key-up may arrive after the user has already released a modifier. Always close a session
        // that this monitor opened, otherwise dictation can remain stuck in the listening state.
        if event.type == .keyUp, keyIsDown {
            keyIsDown = false
            onRelease()
            return true
        }

        let modifiers = event.modifierFlags.intersection(Self.relevantModifiers)
        guard modifiers == binding.modifiers.intersection(Self.relevantModifiers) else {
            return false
        }

        switch event.type {
        case .keyDown where !event.isARepeat && !keyIsDown:
            keyIsDown = true
            onPress()
        default:
            return false
        }
        return true
    }

    private func handleFunctionKey(_ event: NSEvent) -> Bool {
        guard event.type == .flagsChanged, event.keyCode == 63 else { return false }
        let isDown = event.modifierFlags.contains(.function)
        if isDown, !keyIsDown {
            keyIsDown = true
            onPress()
        } else if !isDown, keyIsDown {
            keyIsDown = false
            onRelease()
        }
        return true
    }
}
