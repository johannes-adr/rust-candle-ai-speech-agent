// Zentrale Stilkonstanten der Oma-Oberfläche (PLAN.md §3, Regel 2).
// Die Werte hier sind Abnahmekriterien; App-Tests/OmaRulesTests.swift prüft sie.
import AppKit
import SwiftUI

enum OmaStyle {
    /// Kleinste erlaubte Schrift im normalen Bedienteil (pt).
    static let minTextSize: CGFloat = 20
    static let bodySize: CGFloat = 22
    /// Überschriften mindestens 30 pt.
    static let minHeadingSize: CGFloat = 30
    static let headingSize: CGFloat = 34
    static let titleSize: CGFloat = 42
    static let buttonTextSize: CGFloat = 24
    static let buttonIconSize: CGFloat = 26
    /// Knöpfe mindestens 60 pt hoch.
    static let minButtonHeight: CGFloat = 60
    static let buttonHeight: CGFloat = 68
    static let minContrast: Double = 7
    /// Rahmen und Symbole (keine Schrift) brauchen mindestens 3:1.
    static let minNonTextContrast: Double = 3

    static let spacing: CGFloat = 24
    static let cornerRadius: CGFloat = 18
    static let contentWidth: CGFloat = 980

    static let bodyFont = Font.system(size: bodySize)
    static let bodyBold = Font.system(size: bodySize, weight: .semibold)
    static let headingFont = Font.system(size: headingSize, weight: .bold)
    static let titleFont = Font.system(size: titleSize, weight: .bold)
    static let buttonFont = Font.system(size: buttonTextSize, weight: .semibold)
}

// MARK: Farben

struct RGB: Sendable, Equatable {
    var r: Double
    var g: Double
    var b: Double

    init(_ hex: UInt32) {
        r = Double((hex >> 16) & 0xFF) / 255
        g = Double((hex >> 8) & 0xFF) / 255
        b = Double(hex & 0xFF) / 255
    }

    /// Relative Leuchtdichte nach WCAG 2.x.
    var luminance: Double {
        func lin(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
    }

    func contrast(with other: RGB) -> Double {
        let a = luminance, b = other.luminance
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
}

/// Alle Farben für einen Darstellungsmodus. Hell: dunkle Schrift auf hellem Grund.
struct OmaScheme: Sendable {
    var background: RGB
    var surface: RGB
    var text: RGB
    var secondaryText: RGB
    var primaryFill: RGB
    var primaryLabel: RGB
    var secondaryFill: RGB
    var secondaryLabel: RGB
    var border: RGB
    var track: RGB
}

enum OmaPalette {
    static let light = OmaScheme(
        background: RGB(0xFBF8F1), surface: RGB(0xFFFFFF),
        text: RGB(0x14161A), secondaryText: RGB(0x3A3F47),
        primaryFill: RGB(0x0B3D91), primaryLabel: RGB(0xFFFFFF),
        secondaryFill: RGB(0xDCE6F5), secondaryLabel: RGB(0x0B2A5B),
        border: RGB(0x0B3D91), track: RGB(0x6B7280))
    static let dark = OmaScheme(
        background: RGB(0x17181B), surface: RGB(0x24262B),
        text: RGB(0xF4F5F7), secondaryText: RGB(0xD0D4DA),
        primaryFill: RGB(0xA9C8FF), primaryLabel: RGB(0x04193D),
        secondaryFill: RGB(0x33405A), secondaryLabel: RGB(0xEAF1FF),
        border: RGB(0xA9C8FF), track: RGB(0x9AA3B2))

    /// Alle Schrift-auf-Grund-Paare (Name, Vordergrund, Hintergrund) für die Kontrastprüfung.
    static func textPairs(_ s: OmaScheme) -> [(String, RGB, RGB)] {
        [
            ("Text/Hintergrund", s.text, s.background),
            ("Text/Fläche", s.text, s.surface),
            ("Zweittext/Hintergrund", s.secondaryText, s.background),
            ("Zweittext/Fläche", s.secondaryText, s.surface),
            ("Hauptknopf", s.primaryLabel, s.primaryFill),
            ("Nebenknopf", s.secondaryLabel, s.secondaryFill),
            ("Nebenknopf auf Fläche", s.secondaryLabel, s.secondaryFill),
        ]
    }

    /// Rahmen/Balken gegen den Untergrund (mindestens 3:1).
    static func nonTextPairs(_ s: OmaScheme) -> [(String, RGB, RGB)] {
        [
            ("Rahmen/Hintergrund", s.border, s.background),
            ("Rahmen/Fläche", s.border, s.surface),
            ("Balkenspur/Hintergrund", s.track, s.background),
            ("Hauptknopf/Hintergrund", s.primaryFill, s.background),
        ]
    }
}

extension Color {
    fileprivate static func dynamic(_ light: RGB, _ dark: RGB) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let c = isDark ? dark : light
            return NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: 1)
        })
    }

    static let omaBackground = dynamic(OmaPalette.light.background, OmaPalette.dark.background)
    static let omaSurface = dynamic(OmaPalette.light.surface, OmaPalette.dark.surface)
    static let omaText = dynamic(OmaPalette.light.text, OmaPalette.dark.text)
    static let omaSecondaryText = dynamic(OmaPalette.light.secondaryText, OmaPalette.dark.secondaryText)
    static let omaPrimaryFill = dynamic(OmaPalette.light.primaryFill, OmaPalette.dark.primaryFill)
    static let omaPrimaryLabel = dynamic(OmaPalette.light.primaryLabel, OmaPalette.dark.primaryLabel)
    static let omaSecondaryFill = dynamic(OmaPalette.light.secondaryFill, OmaPalette.dark.secondaryFill)
    static let omaSecondaryLabel = dynamic(OmaPalette.light.secondaryLabel, OmaPalette.dark.secondaryLabel)
    static let omaBorder = dynamic(OmaPalette.light.border, OmaPalette.dark.border)
    static let omaTrack = dynamic(OmaPalette.light.track, OmaPalette.dark.track)
}

// MARK: Knöpfe

enum OmaButtonKind { case primary, secondary }

/// Großer Knopf: mindestens 60 pt hoch, Symbol und Wort, gut sichtbarer Rand. Keine Hover-Effekte.
struct OmaButtonStyle: ButtonStyle {
    var kind: OmaButtonKind = .secondary
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let fill: Color = kind == .primary ? .omaPrimaryFill : .omaSecondaryFill
        let label: Color = kind == .primary ? .omaPrimaryLabel : .omaSecondaryLabel
        configuration.label
            .font(OmaStyle.buttonFont)
            .labelStyle(OmaLabelStyle())
            .foregroundStyle(label)
            .padding(.horizontal, 28)
            .frame(minHeight: OmaStyle.buttonHeight)
            .background(fill, in: RoundedRectangle(cornerRadius: OmaStyle.cornerRadius))
            .overlay(RoundedRectangle(cornerRadius: OmaStyle.cornerRadius).stroke(Color.omaBorder, lineWidth: 2))
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.45)
            .contentShape(RoundedRectangle(cornerRadius: OmaStyle.cornerRadius))
    }
}

struct OmaLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 12) {
            configuration.icon.font(.system(size: OmaStyle.buttonIconSize, weight: .semibold))
            configuration.title
        }
    }
}

/// Knopf mit Symbol und Wort.
struct OmaButton: View {
    var title: LocalizedStringKey
    var systemImage: String
    var kind: OmaButtonKind = .secondary
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
        }
        .buttonStyle(OmaButtonStyle(kind: kind))
    }
}

/// Fortschrittsbalken ohne durchscheinende Materialien.
struct OmaProgressBar: View {
    var fraction: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.omaSurface)
                Capsule().stroke(Color.omaTrack, lineWidth: 2)
                Capsule().fill(Color.omaPrimaryFill)
                    .frame(width: max(geo.size.height, geo.size.width * min(max(fraction, 0), 1)))
            }
        }
        .frame(height: 32)
        .accessibilityElement()
        .accessibilityValue(Text("\(Int((fraction * 100).rounded())) %"))
    }
}

/// Weiße bzw. dunkle Fläche für Karten.
struct OmaCard: ViewModifier {
    var selected = false
    func body(content: Content) -> some View {
        content
            .padding(22)
            .background(Color.omaSurface, in: RoundedRectangle(cornerRadius: OmaStyle.cornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: OmaStyle.cornerRadius)
                    .stroke(Color.omaBorder, lineWidth: selected ? 5 : 1.5))
    }
}

extension View {
    func omaCard(selected: Bool = false) -> some View { modifier(OmaCard(selected: selected)) }
}
