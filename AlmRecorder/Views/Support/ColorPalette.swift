import SwiftUI

// Centralized color helpers: one hex parser, one deterministic speaker color, the rank palette.
// Kept data-only / aesthetic-neutral (no gradients or tints).
extension Color {

    /// Build a Color from a 6-digit hex string ("#FF6B6B" or "FF6B6B").
    /// Returns `.gray` for malformed input (preserves the prior fallback behavior).
    init(hex: String) {
        let sanitized = hex
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")
        guard sanitized.count == 6, let rgb = UInt64(sanitized, radix: 16) else {
            self = .gray
            return
        }
        self.init(
            red:   Double((rgb >> 16) & 0xFF) / 255.0,
            green: Double((rgb >> 8) & 0xFF) / 255.0,
            blue:  Double(rgb & 0xFF) / 255.0
        )
    }

    /// Deterministic, stable-across-launches color for a speaker/identity.
    /// djb2 hash of `seed` → hue at fixed saturation/brightness. This is the single source of
    /// truth for speaker colors (`SpeakerProfile.avatarColor` delegates here). Unlike Swift's
    /// `String.hashValue`, the result never changes between app launches.
    static func speakerColor(for seed: String) -> Color {
        var hash: UInt64 = 5381
        for byte in seed.utf8 {
            hash = ((hash &<< 5) &+ hash) &+ UInt64(byte)
        }
        let hue = Double(hash % 360) / 360.0
        return Color(hue: hue, saturation: 0.6, brightness: 0.8)
    }

    /// Speaker color preferring a stable UUID, falling back to the display label, else `.gray`.
    static func speakerColor(uuid: String?, label: String?) -> Color {
        if let uuid, !uuid.isEmpty { return speakerColor(for: uuid) }
        if let label, !label.isEmpty { return speakerColor(for: label) }
        return .gray
    }

    // Rank / medal palette (moved out of SearchView).
    static let gold   = Color(red: 1.0,  green: 0.84, blue: 0.0)
    static let silver = Color(red: 0.75, green: 0.75, blue: 0.75)
    static let bronze = Color(red: 0.8,  green: 0.5,  blue: 0.2)
}
