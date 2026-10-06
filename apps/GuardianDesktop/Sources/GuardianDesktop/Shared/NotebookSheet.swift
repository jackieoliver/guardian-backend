import GuardianDesktopCore
import SwiftUI

struct NotebookSheet<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ZStack(alignment: .topLeading) {
            NotebookSheetBackground()

            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct NotebookSheetBackground: View {
    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(Color.white.opacity(0.58))
                .overlay(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .stroke(Color.white.opacity(0.44), lineWidth: 1)
                )
                .shadow(color: ArchiveTheme.panelShadow, radius: 18, y: 10)

            VStack(spacing: 28) {
                ForEach(0 ..< 14, id: \.self) { _ in
                    Rectangle()
                        .fill(ArchiveTheme.line.opacity(0.18))
                        .frame(height: 1)
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 26)
            .padding(.bottom, 18)

            Rectangle()
                .fill(Color(red: 0.77, green: 0.43, blue: 0.43).opacity(0.18))
                .frame(width: 1)
                .padding(.leading, 26)
                .padding(.vertical, 18)
        }
    }
}
