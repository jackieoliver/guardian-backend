import GuardianDesktopCore
import SwiftUI

extension View {
    func guardianPanel(cornerRadius: CGFloat, style: GuardianPanelStyle = .chrome) -> some View {
        background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(style == .chrome ? AnyShapeStyle(.ultraThinMaterial) : AnyShapeStyle(ArchiveTheme.contentSurface))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: style.gradientColors,
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(style.strokeColor, lineWidth: 1)
        )
        .shadow(color: style.shadowColor, radius: style.shadowRadius, y: style.shadowYOffset)
    }
}

enum GuardianPanelStyle {
    case chrome
    case content

    var gradientColors: [Color] {
        switch self {
        case .chrome:
            [ArchiveTheme.glassTint, Color.white.opacity(0.06)]
        case .content:
            [Color.white.opacity(0.12), ArchiveTheme.paper.opacity(0.08)]
        }
    }

    var strokeColor: Color {
        switch self {
        case .chrome:
            ArchiveTheme.chromeStroke.opacity(0.7)
        case .content:
            ArchiveTheme.contentStroke
        }
    }

    var shadowColor: Color {
        switch self {
        case .chrome:
            ArchiveTheme.panelShadow
        case .content:
            ArchiveTheme.contentShadow
        }
    }

    var shadowRadius: CGFloat {
        switch self {
        case .chrome:
            18
        case .content:
            10
        }
    }

    var shadowYOffset: CGFloat {
        switch self {
        case .chrome:
            10
        case .content:
            5
        }
    }
}
