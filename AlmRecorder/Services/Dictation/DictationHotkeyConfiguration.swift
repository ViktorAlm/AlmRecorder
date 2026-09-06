import AppKit
import Foundation

struct DictationHotkeyBinding: Equatable, Sendable {
    let keyCode: UInt16?
    let modifiersRawValue: UInt
    let keyLabel: String

    var modifiers: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: modifiersRawValue)
    }

    var isFunctionOnly: Bool {
        keyCode == nil && modifiers == .function
    }

    var displayName: String {
        if isFunctionOnly { return "Fn" }
        return Self.modifierGlyphs(modifiers) + keyLabel
    }

    init(keyCode: UInt16?, modifiers: NSEvent.ModifierFlags, keyLabel: String) {
        self.keyCode = keyCode
        modifiersRawValue = modifiers.rawValue
        self.keyLabel = keyLabel
    }

    private static func modifierGlyphs(_ modifiers: NSEvent.ModifierFlags) -> String {
        var result = ""
        if modifiers.contains(.control) { result += "⌃" }
        if modifiers.contains(.option) { result += "⌥" }
        if modifiers.contains(.shift) { result += "⇧" }
        if modifiers.contains(.command) { result += "⌘" }
        if modifiers.contains(.function) { result += "Fn " }
        return result
    }
}

enum DictationHotkeyPreset: String, CaseIterable, Identifiable {
    case function
    case controlOptionSpace
    case commandShiftSpace
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .function: return "Fn (Willow style)"
        case .controlOptionSpace: return "Control–Option–Space"
        case .commandShiftSpace: return "Command–Shift–Space"
        case .custom: return "Custom…"
        }
    }

    var binding: DictationHotkeyBinding? {
        switch self {
        case .function:
            return .init(keyCode: nil, modifiers: .function, keyLabel: "Fn")
        case .controlOptionSpace:
            return .init(
                keyCode: 49,
                modifiers: [.control, .option],
                keyLabel: "Space"
            )
        case .commandShiftSpace:
            return .init(
                keyCode: 49,
                modifiers: [.command, .shift],
                keyLabel: "Space"
            )
        case .custom:
            return nil
        }
    }
}

enum DictationHotkeySettings {
    static let presetKey = "dictation.hotkey.preset"
    static let customKeyCodeKey = "dictation.hotkey.custom.keyCode"
    static let customModifiersKey = "dictation.hotkey.custom.modifiers"
    static let customLabelKey = "dictation.hotkey.custom.label"

    static func selectedPreset(
        defaults: UserDefaults = .standard
    ) -> DictationHotkeyPreset {
        guard let rawValue = defaults.string(forKey: presetKey),
              let preset = DictationHotkeyPreset(rawValue: rawValue) else {
            return .function
        }
        return preset
    }

    static func currentBinding(
        defaults: UserDefaults = .standard
    ) -> DictationHotkeyBinding {
        let preset = selectedPreset(defaults: defaults)
        if let binding = preset.binding { return binding }
        return customBinding(defaults: defaults)
            ?? DictationHotkeyPreset.function.binding!
    }

    static func select(
        _ preset: DictationHotkeyPreset,
        defaults: UserDefaults = .standard
    ) {
        defaults.set(preset.rawValue, forKey: presetKey)
    }

    static func saveCustom(
        _ binding: DictationHotkeyBinding,
        defaults: UserDefaults = .standard
    ) {
        guard let keyCode = binding.keyCode, !binding.modifiers.isEmpty else { return }
        defaults.set(Int(keyCode), forKey: customKeyCodeKey)
        defaults.set(Int(binding.modifiersRawValue), forKey: customModifiersKey)
        defaults.set(binding.keyLabel, forKey: customLabelKey)
        select(.custom, defaults: defaults)
    }

    static func customBinding(
        defaults: UserDefaults = .standard
    ) -> DictationHotkeyBinding? {
        guard defaults.object(forKey: customKeyCodeKey) != nil,
              defaults.object(forKey: customModifiersKey) != nil else {
            return nil
        }
        let keyCode = defaults.integer(forKey: customKeyCodeKey)
        let modifiers = defaults.integer(forKey: customModifiersKey)
        guard keyCode >= 0, keyCode <= Int(UInt16.max), modifiers > 0 else {
            return nil
        }
        return DictationHotkeyBinding(
            keyCode: UInt16(keyCode),
            modifiers: NSEvent.ModifierFlags(rawValue: UInt(modifiers)),
            keyLabel: defaults.string(forKey: customLabelKey) ?? "Key"
        )
    }
}
