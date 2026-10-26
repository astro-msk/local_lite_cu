import AppKit
import SwiftUI

enum AppAppearance: String, CaseIterable, Identifiable {
    case light = "Light"
    case dark = "Dark"
    case system = "System"

    static let storageKey = "appAppearance"
    var id: String { rawValue }
    var colorScheme: ColorScheme? {
        switch self {
        case .light: return .light
        case .dark: return .dark
        case .system: return nil
        }
    }
}

enum Palette {
    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        func color(_ hex: UInt32) -> NSColor {
            NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
                    green: CGFloat((hex >> 8) & 0xff) / 255,
                    blue: CGFloat(hex & 0xff) / 255, alpha: 1)
        }
        return Color(nsColor: NSColor(name: nil) { appearance in
            color(appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light)
        })
    }

    static let background = adaptive(light: 0xFFFFFF, dark: 0x111614)
    static let sidebar = adaptive(light: 0xF6F8F7, dark: 0x171D19)
    static let panel = adaptive(light: 0xFFFFFF, dark: 0x1B221E)
    static let elevated = adaptive(light: 0xF0F3F1, dark: 0x273029)
    static let line = adaptive(light: 0xDDE4DF, dark: 0x354038)
    static let text = adaptive(light: 0x202A24, dark: 0xEAF0E9)
    static let secondary = adaptive(light: 0x657068, dark: 0xA2B0A5)
    static let accent = adaptive(light: 0x247246, dark: 0x8DD5A6)
    static let amber = adaptive(light: 0x8C6411, dark: 0xEAD078)
    static let blue = adaptive(light: 0x175EC6, dark: 0x93BAFF)
    static let danger = adaptive(light: 0xB42F37, dark: 0xFF969C)
    static let brandFill = Color(red: 0.80, green: 0.93, blue: 0.43)
    static let onBrand = Color(red: 0.055, green: 0.065, blue: 0.065)
}

enum ButtonTone {
    case blue, green, yellow, red, neutral

    var fill: Color {
        switch self {
        case .blue: return Color(red: 0.13, green: 0.39, blue: 0.84)
        case .green: return Color(red: 0.13, green: 0.46, blue: 0.27)
        case .yellow: return Color(red: 0.96, green: 0.81, blue: 0.27)
        case .red: return Color(red: 0.79, green: 0.18, blue: 0.22)
        case .neutral: return Palette.elevated
        }
    }

    var foreground: Color {
        switch self {
        case .yellow: return Color(red: 0.22, green: 0.17, blue: 0.03)
        case .neutral: return Palette.text
        default: return .white
        }
    }
}
