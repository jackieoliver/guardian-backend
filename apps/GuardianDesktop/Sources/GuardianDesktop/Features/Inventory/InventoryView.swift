import GuardianDesktopCore
import SwiftUI

struct InventoryView: View {
    @Bindable var model: ArchiveViewModel
    @Bindable var inventoryStore: SourceInventoryStore
    @Bindable var authSession: GoogleAuthSession
    @Binding var timelineScrollPosition: String?

    private let laneLabelWidth: CGFloat = 152
    private let scoreMetrics = ScoreMetrics()

    private var displayedBooks: [SourceBook] {
        inventoryStore.inventorySources.map { source in
            inventoryStore.displayedSourceBook(for: source, measures: model.snapshot.measures)
        }
    }

    private var displayedLanes: [PerspectiveLane] {
        displayedBooks.map { source in
            inventoryStore.perspectiveLane(for: source, measures: model.snapshot.measures)
        }
    }

    private var selectedDisplayedMeasureSources: [PerspectiveLane] {
        guard let selectedMeasureID = model.selectedMeasureID else {
            return []
        }
        return displayedLanes.filter { $0.coverage(for: selectedMeasureID) != .none }
    }

    private var focusedMeasure: PerspectiveMeasure? {
        guard let focusedMeasureID = model.focusedMeasureID else {
            return nil
        }
        return model.snapshot.measures.first { $0.id == focusedMeasureID }
    }

    private var focusedMeasureIndex: Int? {
        guard let focusedMeasureID = focusedMeasure?.id else {
            return nil
        }
        return model.snapshot.measures.firstIndex { $0.id == focusedMeasureID }
    }

    private var displayedImportQueue: [GuardianImportQueueItem] {
        authSession.currentImportQueue
    }

    private var displayedImportQueueBySourceID: [String: GuardianImportQueueItem] {
        var itemsBySourceID: [String: GuardianImportQueueItem] = [:]
        for item in displayedImportQueue {
            itemsBySourceID[item.ownedSourceID] = itemsBySourceID[item.ownedSourceID] ?? item
        }
        return itemsBySourceID
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                perspectiveTimelineCard

                if model.selectedMeasure != nil {
                    detailCard
                }

                sourceLibraryCard
            }
            .padding(.bottom, 18)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var perspectiveTimelineCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            timelineHeader

            HStack(alignment: .top, spacing: 18) {
                sourceRail

                ScrollViewReader { proxy in
                    ScrollView(.horizontal) {
                        ZStack(alignment: .topLeading) {
                            VStack(alignment: .leading, spacing: 16) {
                                scoreHeader

                                VStack(alignment: .leading, spacing: scoreMetrics.interStaffGap) {
                                    ForEach(displayedLanes) { lane in
                                        PerspectiveLaneMeasuresRow(
                                            lane: lane,
                                            measures: model.snapshot.measures,
                                            selectedMeasureID: model.selectedMeasureID,
                                            currentMeasureID: model.currentMeasureID,
                                            metrics: scoreMetrics
                                        )
                                    }
                                }
                            }
                            .id("timeline-lanes")

                            measureColumnTapOverlay
                        }
                        .padding(.bottom, 6)
                        .padding(.trailing, scoreMetrics.trailingFocusInset)
                        .scrollTargetLayout()
                    }
                    .scrollIndicators(.hidden)
                    .scrollTargetBehavior(.viewAligned)
                    .onAppear {
                        scrollTimelineToFocus(using: proxy)
                    }
                    .onChange(of: timelineScrollPosition) { _, _ in
                        scrollTimelineToFocus(using: proxy)
                    }
                    .onChange(of: model.selectedMeasureID) { _, _ in
                        scrollTimelineToFocus(using: proxy)
                    }
                    .onChange(of: model.currentMeasureID) { _, _ in
                        scrollTimelineToFocus(using: proxy)
                    }
                }
            }
        }
        .padding(18)
        .guardianPanel(cornerRadius: 24, style: .content)
        .accessibilityIdentifier("container.timeline")
    }

    private var timelineHeader: some View {
        HStack(alignment: .center, spacing: 12) {
            Text("Lifelog")
                .font(.system(size: 20, weight: .semibold, design: .serif))
                .foregroundStyle(ArchiveTheme.ink)
                .accessibilityIdentifier("title.timeline")

            Spacer(minLength: 12)

            HStack(spacing: 8) {
                timelineJumpButton(
                    systemName: "chevron.left",
                    title: "Previous period",
                    disabled: canFocusPreviousMeasure == false
                ) {
                    focusAdjacentMeasure(-1)
                }

                Text(focusedMeasure?.rangeLabel ?? "Current period")
                    .font(.system(size: 13, weight: .semibold, design: .serif))
                    .foregroundStyle(ArchiveTheme.ink.opacity(0.8))
                    .lineLimit(1)
                    .frame(minWidth: 112)

                timelineJumpButton(
                    systemName: "chevron.right",
                    title: "Next period",
                    disabled: canFocusNextMeasure == false
                ) {
                    focusAdjacentMeasure(1)
                }
            }
        }
    }

    private var sourceRail: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Sources")
                    .font(.system(size: 13, weight: .semibold, design: .serif))
                    .foregroundStyle(ArchiveTheme.ink.opacity(0.75))
            }
            .frame(width: laneLabelWidth, height: scoreMetrics.headerHeight, alignment: .leading)

            VStack(alignment: .leading, spacing: scoreMetrics.interStaffGap) {
                ForEach(displayedLanes) { lane in
                    Text(lane.name)
                        .font(.system(size: 16, weight: .semibold, design: .serif))
                        .foregroundStyle(ArchiveTheme.ink)
                        .frame(width: laneLabelWidth, height: scoreMetrics.rowHeight, alignment: .leading)
                }
            }
        }
        .frame(width: laneLabelWidth, alignment: .leading)
    }

    private var scoreHeader: some View {
        HStack(spacing: 0) {
            ForEach(model.snapshot.measures) { measure in
                MeasureHeaderCell(
                    measure: measure,
                    isSelected: measure.id == model.selectedMeasureID,
                    isCurrentMeasure: measure.id == model.currentMeasureID,
                    metrics: scoreMetrics
                )
                .id("measure-\(measure.id)")
            }
        }
    }

    private var measureColumnTapOverlay: some View {
        HStack(spacing: 0) {
            ForEach(model.snapshot.measures) { measure in
                Button {
                    focusMeasure(measure.id)
                } label: {
                    Rectangle()
                        .fill(Color.clear)
                        .frame(
                            width: scoreMetrics.measureWidth,
                            height: scoreMetrics.columnInteractionHeight(laneCount: displayedLanes.count)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("timeline.column.\(measure.id)")
            }
        }
    }

    private var detailCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(model.selectedMeasure?.rangeLabel ?? "Measure")
                .font(.system(size: 19, weight: .semibold, design: .serif))
                .foregroundStyle(ArchiveTheme.ink)

            Text(detailMeasureNote)
                .font(.system(size: 14, weight: .regular, design: .serif))
                .foregroundStyle(ArchiveTheme.ink.opacity(0.75))

            Text(detailSourceLine)
                .font(.system(size: 13, weight: .medium, design: .serif))
                .foregroundStyle(ArchiveTheme.ink.opacity(0.9))
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .guardianPanel(cornerRadius: 24, style: .content)
        .accessibilityIdentifier("drawer.segmentDetail")
    }

    private var detailMeasureNote: String {
        let items = selectedDisplayedMeasureSources.map(\.name)
        if items.isEmpty {
            return "No source material is present in this measure yet."
        }
        if items.count == 1 {
            return "\(items[0]) carries this measure."
        }
        return "\(items.count) sources contribute here: \(items.prefix(3).joined(separator: ", "))."
    }

    private var detailSourceLine: String {
        guard let selectedMeasureID = model.selectedMeasureID else {
            return "No source material is present in this measure yet."
        }

        let items = selectedDisplayedMeasureSources.map { lane in
            "\(lane.name) (\(lane.coverage(for: selectedMeasureID).detailText))"
        }

        if items.isEmpty {
            return "No source material is present in this measure yet."
        }

        return "Present in this measure: \(items.joined(separator: ", "))"
    }

    private var sourceLibraryCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Streams")
                .font(.system(size: 20, weight: .semibold, design: .serif))
                .foregroundStyle(ArchiveTheme.ink)

            ScrollView(.horizontal) {
                HStack(spacing: 12) {
                    ForEach(displayedBooks) { book in
                        sourceCard(for: book)
                    }
                }
                .padding(.bottom, 4)
            }
            .scrollIndicators(.hidden)
        }
        .padding(16)
        .guardianPanel(cornerRadius: 24, style: .content)
        .accessibilityIdentifier("card.sourceLibrary")
    }

    private func scrollTimelineToFocus(using proxy: ScrollViewProxy) {
        let resolvedTarget = timelineScrollPosition
            ?? model.selectedMeasureID.map { "measure-\($0)" }
            ?? model.currentMeasureID.map { "measure-\($0)" }
        guard let target = resolvedTarget else {
            return
        }

        func scroll() {
            withAnimation(.easeInOut(duration: 0.22)) {
                proxy.scrollTo(target, anchor: .center)
            }
        }

        DispatchQueue.main.async {
            scroll()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            scroll()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
            scroll()
        }
    }

    @ViewBuilder
    private func sourceCard(for book: SourceBook) -> some View {
        let card = SourceSheetCard(
            book: book,
            importQueueItem: displayedImportQueueBySourceID[book.id],
            isRegenerating: model.snapshot.regenerationSourceID == book.id,
            disableAnimations: model.environment.disableAnimations
        )

        if authSession.currentUser != nil {
            Button {
                inventoryStore.showSourceImportDialog(for: book.id)
            } label: {
                card
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("button.openSourceImport.\(book.id)")
        } else {
            card
        }
    }

    private func focusMeasure(_ measureID: String) {
        model.focusMeasure(measureID)
        timelineScrollPosition = "measure-\(measureID)"
    }

    private func focusAdjacentMeasure(_ offset: Int) {
        model.focusAdjacentMeasure(offset: offset)
        if let focusedMeasureID = model.focusedMeasureID {
            timelineScrollPosition = "measure-\(focusedMeasureID)"
        }
    }

    private var canFocusPreviousMeasure: Bool {
        guard let focusedMeasureIndex else {
            return false
        }
        return focusedMeasureIndex > 0
    }

    private var canFocusNextMeasure: Bool {
        guard let focusedMeasureIndex else {
            return false
        }
        return focusedMeasureIndex < model.snapshot.measures.count - 1
    }

    private func timelineJumpButton(
        systemName: String,
        title: String,
        disabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(ArchiveTheme.ink.opacity(disabled ? 0.35 : 0.86))
                .frame(width: 28, height: 28)
                .background(
                    Circle()
                        .fill(Color.white.opacity(disabled ? 0.22 : 0.44))
                )
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(title)
    }
}
