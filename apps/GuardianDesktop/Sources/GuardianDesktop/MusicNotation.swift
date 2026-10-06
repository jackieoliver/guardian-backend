import CoreText
import GuardianDesktopCore
import SwiftUI

enum MusicNotation {
    static let fontName = "Bravura"

    private static let quarterScalar = UnicodeScalar(0xE1D5)!
    private static let wholeScalar = UnicodeScalar(0xE1D2)!

    static func registerFont() {
        guard let fontURL = Bundle.main.url(forResource: "Bravura", withExtension: "otf") else {
            return
        }

        CTFontManagerRegisterFontsForURL(fontURL as CFURL, .process, nil)
    }

    static func glyph(for coverage: PerspectiveCoverage) -> String {
        switch coverage {
        case .none:
            ""
        case .oneQuarter, .twoQuarters, .threeQuarters:
            String(Character(quarterScalar))
        case .full:
            String(Character(wholeScalar))
        }
    }

    static func font(size: CGFloat) -> Font {
        .custom(fontName, size: size)
    }
}
