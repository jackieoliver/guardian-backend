import GuardianDesktopCore
import SwiftUI

struct MeasureHeaderCell: View {
    let measure: PerspectiveMeasure
    let isSelected: Bool
    let isCurrentMeasure: Bool
    let metrics: ScoreMetrics

    var body: some View {
        VStack(spacing: 5) {
            Text(measure.shortLabel)
                .font(.system(size: 14, weight: .semibold, design: .serif))
            Text(isCurrentMeasure ? "Today" : "2 days")
                .font(.system(size: 11, weight: .regular, design: .serif))
                .foregroundStyle(ArchiveTheme.ink.opacity(isCurrentMeasure ? 0.72 : 0.5))
        }
        .foregroundStyle(ArchiveTheme.ink.opacity(0.88))
        .frame(width: metrics.measureWidth, height: metrics.headerHeight)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(ArchiveTheme.timelineSelection.opacity(0.92))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
            } else if isCurrentMeasure {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(ArchiveTheme.currentMeasureBand)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(ArchiveTheme.currentMeasureStroke, lineWidth: 1)
                    )
                    .shadow(color: ArchiveTheme.currentMeasureGlow, radius: 16)
                    .padding(.horizontal, 4)
            }
        }
    }
}

struct PerspectiveLaneMeasuresRow: View {
    let lane: PerspectiveLane
    let measures: [PerspectiveMeasure]
    let selectedMeasureID: String?
    let currentMeasureID: String?
    let metrics: ScoreMetrics

    var body: some View {
        ZStack(alignment: .topLeading) {
            HStack(spacing: 0) {
                ForEach(measures) { measure in
                    PerspectiveMeasureCell(
                        coverage: lane.coverage(for: measure.id),
                        isSelected: selectedMeasureID == measure.id,
                        isCurrentMeasure: currentMeasureID == measure.id,
                        metrics: metrics
                    )
                    .accessibilityIdentifier("timeline.measure.\(lane.id).\(measure.id)")
                }
            }

            tieOverlay
        }
    }

    private var tieOverlay: some View {
        Canvas { context, _ in
            for index in measures.indices.dropLast() {
                let currentCoverage = lane.coverage(for: measures[index].id)
                let nextCoverage = lane.coverage(for: measures[index + 1].id)
                guard currentCoverage != .none, nextCoverage != .none else {
                    continue
                }

                let start = CGPoint(
                    x: (CGFloat(index) * metrics.measureWidth) + (metrics.measureWidth * 0.66),
                    y: metrics.tieBaselineY
                )
                let end = CGPoint(
                    x: (CGFloat(index + 1) * metrics.measureWidth) + (metrics.measureWidth * 0.34),
                    y: metrics.tieBaselineY
                )
                let control = CGPoint(
                    x: (start.x + end.x) / 2,
                    y: metrics.tieControlY
                )

                var tie = Path()
                tie.move(to: start)
                tie.addQuadCurve(to: end, control: control)

                context.stroke(
                    tie,
                    with: .color(ArchiveTheme.timelineTie),
                    style: StrokeStyle(
                        lineWidth: metrics.tieLineWidth,
                        lineCap: .round,
                        lineJoin: .round
                    )
                )
            }
        }
        .frame(
            width: CGFloat(measures.count) * metrics.measureWidth,
            height: metrics.rowHeight
        )
        .allowsHitTesting(false)
    }
}

struct PerspectiveMeasureCell: View {
    let coverage: PerspectiveCoverage
    let isSelected: Bool
    let isCurrentMeasure: Bool
    let metrics: ScoreMetrics

    var body: some View {
        ZStack {
            if isCurrentMeasure {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(ArchiveTheme.currentMeasureBand)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(ArchiveTheme.currentMeasureStroke.opacity(0.65), lineWidth: 1)
                    )
                    .shadow(color: ArchiveTheme.currentMeasureGlow, radius: 14)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 3)
            }

            if isSelected {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(ArchiveTheme.timelineSelection)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 5)
            }

            VStack(spacing: metrics.staffSpace) {
                ForEach(0 ..< metrics.lineCount, id: \.self) { _ in
                    Rectangle()
                        .fill(ArchiveTheme.line.opacity(0.28))
                        .frame(height: metrics.lineThickness)
                }
            }
            .padding(.vertical, metrics.staffInset)

            if coverage != .none {
                notationMark
            }
        }
        .frame(width: metrics.measureWidth, height: metrics.rowHeight)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(ArchiveTheme.line.opacity(0.42))
                .frame(width: metrics.barlineWidth)
        }
    }

    private var notationMark: some View {
        Canvas { context, size in
            let noteColor = ArchiveTheme.timelineFill
            let anchorY = metrics.staffInset + (metrics.staffSpace * 2)

            if coverage == .full {
                let wholeRect = CGRect(
                    x: (size.width - metrics.wholeNoteWidth) / 2,
                    y: anchorY - (metrics.wholeNoteHeight / 2),
                    width: metrics.wholeNoteWidth,
                    height: metrics.wholeNoteHeight
                )

                let wholePath = Ellipse()
                    .path(in: wholeRect)
                    .applying(rotationTransform(for: wholeRect, angle: metrics.noteHeadTilt))
                context.fill(wholePath, with: .color(ArchiveTheme.paper))
                context.stroke(wholePath, with: .color(noteColor), lineWidth: metrics.wholeNoteLineWidth)
            } else {
                let count = coverage.quarterNoteCount
                let totalWidth = CGFloat(max(count - 1, 0)) * metrics.quarterNoteStep
                let startX = (size.width / 2) - (totalWidth / 2)

                for index in 0 ..< count {
                    let centerX = startX + (CGFloat(index) * metrics.quarterNoteStep)
                    let noteheadRect = CGRect(
                        x: centerX - (metrics.quarterNoteHeadWidth / 2),
                        y: anchorY - (metrics.quarterNoteHeadHeight / 2),
                        width: metrics.quarterNoteHeadWidth,
                        height: metrics.quarterNoteHeadHeight
                    )

                    let noteheadPath = Ellipse()
                        .path(in: noteheadRect)
                        .applying(rotationTransform(for: noteheadRect, angle: metrics.noteHeadTilt))
                    context.fill(noteheadPath, with: .color(noteColor))

                    var stem = Path()
                    let stemX = centerX + (metrics.quarterNoteHeadWidth * 0.42)
                    let stemBottom = anchorY + (metrics.quarterNoteHeadHeight * 0.1)
                    stem.move(to: CGPoint(x: stemX, y: stemBottom))
                    stem.addLine(to: CGPoint(x: stemX, y: stemBottom - metrics.quarterStemHeight))
                    context.stroke(stem, with: .color(noteColor), lineWidth: metrics.quarterStemWidth)
                }
            }
        }
        .frame(width: metrics.measureWidth, height: metrics.rowHeight)
    }

    private func rotationTransform(for rect: CGRect, angle: CGFloat) -> CGAffineTransform {
        CGAffineTransform(translationX: rect.midX, y: rect.midY)
            .rotated(by: angle)
            .translatedBy(x: -rect.midX, y: -rect.midY)
    }
}

struct ScoreMetrics {
    let headerHeight: CGFloat = 54
    let staffSpace: CGFloat = 8
    let lineThickness: CGFloat = 1
    let lineCount: Int = 5
    let staffInset: CGFloat = 8
    let interStaffGap: CGFloat = 10
    let measureWidth: CGFloat = 64
    let barlineWidth: CGFloat = 1
    let noteHeadTilt: CGFloat = -.pi / 7
    let wholeNoteWidth: CGFloat = 14
    let wholeNoteHeight: CGFloat = 9
    let wholeNoteLineWidth: CGFloat = 1.4
    let quarterNoteHeadWidth: CGFloat = 11
    let quarterNoteHeadHeight: CGFloat = 8
    let quarterStemHeight: CGFloat = 22
    let quarterStemWidth: CGFloat = 1.6
    let quarterNoteStep: CGFloat = 13
    let tieLineWidth: CGFloat = 2.4
    let focusAnchorX: CGFloat = 0.5
    let trailingFocusInset: CGFloat = 760

    var rowHeight: CGFloat {
        (staffSpace * CGFloat(lineCount - 1)) + (staffInset * 2) + lineThickness
    }

    var tieBaselineY: CGFloat {
        staffInset + (staffSpace * 2) - 12
    }

    var tieControlY: CGFloat {
        tieBaselineY - 12
    }

    func columnInteractionHeight(laneCount: Int) -> CGFloat {
        let rowStackHeight = (CGFloat(laneCount) * rowHeight) + (CGFloat(max(laneCount - 1, 0)) * interStaffGap)
        return headerHeight + 16 + rowStackHeight
    }
}

struct SourceSheetCard: View {
    let book: SourceBook
    let importQueueItem: GuardianImportQueueItem?
    let isRegenerating: Bool
    let disableAnimations: Bool

    private var showsImportProgress: Bool {
        importQueueItem != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 11) {
                SourceSheetIcon(
                    book: book,
                    importQueueItem: importQueueItem,
                    isRegenerating: isRegenerating,
                    disableAnimations: disableAnimations
                )

                VStack(alignment: .leading, spacing: 6) {
                    Text(book.name)
                        .font(.system(size: 13, weight: .semibold, design: .serif))
                        .foregroundStyle(ArchiveTheme.ink)
                        .lineLimit(2)

                    Text(book.detail)
                        .font(.system(size: 11, weight: .regular, design: .serif))
                        .foregroundStyle(ArchiveTheme.ink.opacity(0.72))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)

                    if book.isConnected && showsImportProgress == false {
                        Text("Connected")
                            .font(.system(size: 10, weight: .medium, design: .serif))
                            .foregroundStyle(ArchiveTheme.green)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 0)
            }

            if let importQueueItem {
                ImportProgressBar(
                    progress: importQueueProgress(for: importQueueItem),
                    tint: importQueueTint(for: importQueueItem)
                )
            }
        }
        .frame(width: 168, alignment: .leading)
        .padding(10)
        .guardianPanel(cornerRadius: 20)
        .animation(disableAnimations ? nil : .easeInOut(duration: 0.25), value: isRegenerating)
        .accessibilityIdentifier("sourceBook.\(book.id)")
    }
}

private struct ImportProgressBar: View {
    let progress: Double
    let tint: Color

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(ArchiveTheme.line.opacity(0.18))

                if progress > 0 {
                    Capsule()
                        .fill(tint)
                        .frame(width: geometry.size.width * progress)
                }
            }
        }
        .frame(height: 6)
    }
}

struct SourceSheetIcon: View {
    let book: SourceBook
    let importQueueItem: GuardianImportQueueItem?
    let isRegenerating: Bool
    let disableAnimations: Bool

    private var tint: Color {
        ArchiveTheme.vitalityColor(for: book.vitality)
    }

    var body: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(Color.white.opacity(0.86))
            .frame(width: 54, height: 70)
            .overlay(alignment: .topLeading) {
                foldedCorner
            }
            .overlay {
                staffLines
            }
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: sourceSymbolName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(tint)
                    .padding(7)
            }
            .overlay(alignment: .topTrailing) {
                uploadIndicator
                    .padding(6)
            }
            .overlay(alignment: .center) {
                noteGlyph
            }
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(tint.opacity(0.42), lineWidth: 1.1)
            }
            .shadow(color: tint.opacity(0.14), radius: 14, y: 8)
            .overlay {
                if isRegenerating {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(ArchiveTheme.glow, lineWidth: 4)
                        .shadow(color: ArchiveTheme.glow.opacity(0.7), radius: 16)
                }
            }
    }

    @ViewBuilder
    private var uploadIndicator: some View {
        if let importQueueItem {
            ProgressView()
                .controlSize(.small)
                .tint(importQueueTint(for: importQueueItem))
        } else if book.isConnected {
            Circle()
                .fill(ArchiveTheme.green)
                .frame(width: 10, height: 10)
        }
    }

    private var foldedCorner: some View {
        Path { path in
            path.move(to: CGPoint(x: 44, y: 0))
            path.addLine(to: CGPoint(x: 66, y: 0))
            path.addLine(to: CGPoint(x: 66, y: 22))
            path.closeSubpath()
        }
        .fill(tint.opacity(0.14))
    }

    private var staffLines: some View {
        VStack(spacing: 5) {
            ForEach(0 ..< 5, id: \.self) { _ in
                Capsule()
                    .fill(tint.opacity(0.18))
                    .frame(width: 30, height: 1)
            }
        }
    }

    private var noteGlyph: some View {
        Text(MusicNotation.glyph(for: dominantCoverage))
            .font(MusicNotation.font(size: dominantCoverage == .full ? 24 : 29))
            .foregroundStyle(tint)
            .frame(width: 42, height: 42)
            .offset(x: -2, y: 2)
    }

    private var dominantCoverage: PerspectiveCoverage {
        book.recentCoveragePreview.max { lhs, rhs in
            lhs.rawValue < rhs.rawValue
        } ?? .oneQuarter
    }

    private var sourceSymbolName: String {
        switch book.sourceType {
        case .screenpipe:
            "display"
        case .phoneCapture:
            "iphone.gen3"
        case .djiMic:
            "mic.fill"
        case .gumstickMic:
            "waveform"
        case .gopro:
            "camera.aperture"
        case .insta360:
            "camera.macro"
        case .newCamera:
            "camera.fill"
        }
    }
}

private func importQueueProgress(for item: GuardianImportQueueItem) -> Double {
    let shardCount = max(item.transportShardCount, 1)
    let uploadFraction = Double(item.uploadedTransportShardCount) / Double(shardCount)
    let processingFraction = Double(item.processedTransportShardCount) / Double(shardCount)

    switch item.status {
    case "created":
        return 0
    case "uploading":
        return min(max(uploadFraction * 0.5, 0), 0.5)
    case "processing":
        return min(max(0.5 + (processingFraction * 0.5), 0.5), 1)
    case "completed":
        return 1
    case "failed", "canceled":
        return min(max(0.5 + (processingFraction * 0.5), 0), 1)
    default:
        return min(max(uploadFraction * 0.5, 0), 1)
    }
}

private func importQueueTint(for item: GuardianImportQueueItem) -> Color {
    switch item.status {
    case "created":
        return ArchiveTheme.ink.opacity(0.5)
    case "uploading":
        return ArchiveTheme.green.opacity(0.82)
    case "processing":
        return Color.orange.opacity(0.82)
    case "completed":
        return ArchiveTheme.green
    case "failed":
        return Color.red.opacity(0.82)
    case "canceled":
        return ArchiveTheme.ink.opacity(0.38)
    default:
        return ArchiveTheme.green.opacity(0.72)
    }
}

struct InventoryChoiceView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("A new source is ready")
                .font(.system(size: 24, weight: .semibold, design: .serif))
            Text("Add it to your inventory or swap it with an older source.")
                .font(.system(size: 16, weight: .regular, design: .serif))
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Button("Add to Inventory") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("button.addToInventory")
                Button("Swap Existing Source") { dismiss() }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("button.swapInventoryItem")
            }
        }
        .padding(28)
        .frame(minWidth: 440)
        .accessibilityIdentifier("dialog.inventoryChoice")
    }
}
