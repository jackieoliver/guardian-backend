import SwiftUI

public enum ArchiveTheme {
    public static let paper = Color(red: 0.95, green: 0.93, blue: 0.88)
    public static let ink = Color(red: 0.20, green: 0.18, blue: 0.15)
    public static let green = Color(red: 0.37, green: 0.57, blue: 0.40)
    public static let yellow = Color(red: 0.79, green: 0.66, blue: 0.33)
    public static let blank = Color(red: 0.82, green: 0.78, blue: 0.72)
    public static let line = Color(red: 0.70, green: 0.66, blue: 0.60)
    public static let glow = Color(red: 0.52, green: 0.80, blue: 0.54)
    public static let timelineFill = green
    public static let timelineTie = green.opacity(0.72)
    public static let timelineEmpty = Color.white.opacity(0.18)
    public static let timelineSelection = green.opacity(0.14)
    public static let glassTint = Color.white.opacity(0.28)
    public static let glassStroke = Color.white.opacity(0.52)
    public static let currentMeasureBand = Color.white.opacity(0.26)
    public static let currentMeasureGlow = green.opacity(0.20)
    public static let currentMeasureStroke = green.opacity(0.35)
    public static let shelfSurface = Color.white.opacity(0.34)
    public static let shelfStroke = Color.white.opacity(0.38)
    public static let placardSurface = Color.white.opacity(0.48)
    public static let placardHighlight = Color.white.opacity(0.22)
    public static let placardStroke = Color.white.opacity(0.28)
    public static let emblemSurface = Color.white.opacity(0.72)
    public static let emblemShadow = Color.black.opacity(0.06)
    public static let connectionBlue = Color(red: 0.39, green: 0.58, blue: 0.84)
    public static let paperGlow = Color(red: 0.98, green: 0.96, blue: 0.91)
    public static let panelShadow = Color.black.opacity(0.08)
    public static let contentSurface = Color.white.opacity(0.62)
    public static let contentStroke = Color.white.opacity(0.34)
    public static let contentShadow = Color.black.opacity(0.045)
    public static let chromeSurface = Color.white.opacity(0.22)
    public static let chromeStroke = Color.white.opacity(0.52)

    public static func vitalityColor(for vitality: SourceVitality) -> Color {
        switch vitality {
        case .vital:
            green
        case .fading:
            yellow
        case .dark:
            ink.opacity(0.45)
        }
    }
}
