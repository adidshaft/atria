import SwiftUI

// Exercise catalog (design source: Claude Design "Atria App UI.dc.html",
// section 7c, 2026-08-01 design-parity slice 2).
//
// Rows carry the exercise's own saved history: the real best Epley e1RM, when
// it was last logged, and a sparkline of its saved days. An exercise under the
// three-session floor is dimmed and says how many sets exist instead of
// showing a shape — see `AtriaStrengthProgressPresentation`. The muscle chips
// are the app's real catalog groups, and "New exercise" writes through
// `AtriaWorkoutExerciseCatalog`'s custom-exercise store.

struct AtriaStrengthCatalogView: View {
    let projection: StrengthHistoryProjection
    let now: Date
    let onSelect: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var selectedGroup: String?
    @State private var rows: [AtriaStrengthProgressPresentation.CatalogRow] = []
    /// Muscle groups in catalog order, not in row order, so the chip row keeps
    /// a stable shape while the list re-sorts by recency.
    @State private var groupTitles: [String] = []

    init(projection: StrengthHistoryProjection,
         now: Date = Date(),
         onSelect: @escaping (String) -> Void) {
        self.projection = projection
        self.now = now
        self.onSelect = onSelect
    }

    // MARK: - Derived (kept out of render blocks)

    private var visibleRows: [AtriaStrengthProgressPresentation.CatalogRow] {
        AtriaStrengthProgressPresentation.filter(rows, search: search, group: selectedGroup)
    }

    private var trimmedSearch: String {
        search.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canAddCustomExercise: Bool {
        guard !trimmedSearch.isEmpty else { return false }
        let key = AtriaStrengthLog.normalized(trimmedSearch)
        return !rows.contains { $0.id == key }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            searchField
            groupChips
            rowList
            newExerciseButton
        }
        .preferredColorScheme(.dark)
        .onAppear(perform: rebuildRows)
    }

    // MARK: - Chrome

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Exercises")
                    .font(.title3.weight(.bold))
                Text("Sorted by most recently logged")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: AtriaDesignTokens.Spacing.sm)
            Button("Done") { dismiss() }
                .font(.subheadline.weight(.bold))
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .padding(.horizontal, AtriaDesignTokens.Spacing.xl)
        .padding(.top, AtriaDesignTokens.Spacing.lg)
    }

    private var searchField: some View {
        HStack(spacing: AtriaDesignTokens.Spacing.sm) {
            Image(systemName: "magnifyingglass")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.secondary)
            TextField("Search or add custom", text: $search)
                .font(.subheadline)
                .textInputAutocapitalization(.sentences)
                .autocorrectionDisabled()
                .submitLabel(.done)
            if !search.isEmpty {
                Button {
                    search = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, AtriaDesignTokens.Spacing.md)
        .padding(.vertical, search.isEmpty ? AtriaDesignTokens.Spacing.md : 0)
        .background(.primary.opacity(0.06),
                    in: RoundedRectangle(cornerRadius: AtriaDesignTokens.Radius.chip, style: .continuous))
        .padding(.horizontal, AtriaDesignTokens.Spacing.xl)
        .padding(.top, AtriaDesignTokens.Spacing.md)
    }

    private var groupChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: AtriaDesignTokens.Spacing.sm) {
                chip(title: "All", isSelected: selectedGroup == nil) { selectedGroup = nil }
                ForEach(groupTitles, id: \.self) { title in
                    chip(title: title, isSelected: selectedGroup == title) {
                        selectedGroup = selectedGroup == title ? nil : title
                    }
                }
            }
            .padding(.horizontal, AtriaDesignTokens.Spacing.xl)
        }
        .padding(.vertical, AtriaDesignTokens.Spacing.md)
    }

    private func chip(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(.bold))
                .foregroundStyle(isSelected ? AtriaStrengthPalette.amberTint : .primary)
                .padding(.horizontal, 13)
                .frame(minHeight: 38)
                .background(isSelected
                            ? AtriaStrengthPalette.amber.opacity(0.20)
                            : Color.primary.opacity(0.06),
                            in: Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private var rowList: some View {
        ScrollView {
            LazyVStack(spacing: AtriaDesignTokens.Spacing.sm) {
                if visibleRows.isEmpty {
                    Text(trimmedSearch.isEmpty
                         ? "No exercises in this group yet."
                         : "No saved exercise matches \u{201C}\(trimmedSearch)\u{201D}.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, AtriaDesignTokens.Spacing.xl)
                }
                ForEach(visibleRows) { row in
                    Button {
                        onSelect(row.name)
                        dismiss()
                    } label: {
                        AtriaStrengthCatalogRow(row: row, now: now)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, AtriaDesignTokens.Spacing.xl)
            .padding(.bottom, AtriaDesignTokens.Spacing.lg)
        }
    }

    private var newExerciseButton: some View {
        Button(action: addCustomExercise) {
            Label(canAddCustomExercise ? "Add \u{201C}\(trimmedSearch)\u{201D}" : "New exercise",
                  systemImage: "plus")
                .font(.subheadline.weight(.bold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
        }
        .atriaCardAction(tint: AtriaStrengthPalette.amber)
        .disabled(!canAddCustomExercise)
        .padding(.horizontal, AtriaDesignTokens.Spacing.xl)
        .padding(.top, AtriaDesignTokens.Spacing.md)
        .padding(.bottom, AtriaDesignTokens.Spacing.lg)
        .accessibilityHint(canAddCustomExercise
                           ? "Saves this name to your own exercises"
                           : "Type a new exercise name to add it")
    }

    // MARK: - Actions

    private func rebuildRows() {
        let groups = AtriaWorkoutExerciseCatalog.allGroups()
        rows = AtriaStrengthProgressPresentation.catalogRows(groups: groups,
                                                             projection: projection,
                                                             now: now)
        var titles = groups.map(\.title)
        for row in rows where !titles.contains(row.group) {
            titles.append(row.group)
        }
        groupTitles = titles
    }

    private func addCustomExercise() {
        guard canAddCustomExercise else { return }
        let name = trimmedSearch
        AtriaWorkoutExerciseCatalog.addCustomExercise(name)
        rebuildRows()
        search = ""
        onSelect(name)
        dismiss()
    }
}

/// One catalog row: real e1RM, real recency, and a sparkline of the exercise's
/// own saved days. Rows under the three-session floor dim and state their set
/// count rather than drawing a shape from one or two points.
struct AtriaStrengthCatalogRow: View {
    let row: AtriaStrengthProgressPresentation.CatalogRow
    let now: Date

    private var subtitle: String {
        guard row.hasEnoughHistory else {
            return AtriaStrengthProgressPresentation.learningText(sessions: row.sessionCount,
                                                                  sets: row.setCount)
        }
        let e1RM = "e1RM \(AtriaStrengthProgressPresentation.weightText(row.e1RM))"
        guard let recency = AtriaStrengthProgressPresentation.recencyText(row.lastLogged, now: now) else {
            return e1RM
        }
        return "\(e1RM) \u{00B7} \(recency)"
    }

    private var trailingNote: String? {
        // Only an exercise that is part-way there gets the countdown; a lift
        // that has never been logged just says so.
        guard !row.hasEnoughHistory, row.sessionCount > 0 else { return nil }
        let text = AtriaStrengthProgressPresentation.needMoreText(sessions: row.sessionCount)
        return text.isEmpty ? nil : text
    }

    var body: some View {
        HStack(spacing: AtriaDesignTokens.Spacing.md) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(row.name)
                        .font(.subheadline.weight(.bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    if row.holdsCurrentRecord {
                        Text("PR")
                            .font(.system(size: 9, weight: .heavy))
                            .foregroundStyle(AtriaStrengthPalette.amberTint)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(AtriaStrengthPalette.amber.opacity(0.2),
                                        in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    }
                }
                Text(subtitle)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let trailingNote {
                    Text(trailingNote)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: AtriaDesignTokens.Spacing.sm)
            AtriaStrengthSparkline(values: row.sparkline)
                .frame(width: 72, height: 34)
        }
        .padding(.horizontal, AtriaDesignTokens.Spacing.md)
        .padding(.vertical, AtriaDesignTokens.Spacing.md)
        .frame(minHeight: 56)
        .opacity(row.hasEnoughHistory ? 1 : 0.55)
        .background(.primary.opacity(0.05),
                    in: RoundedRectangle(cornerRadius: AtriaDesignTokens.Radius.chip, style: .continuous))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(row.name). \(subtitle).")
    }
}

/// Amber sparkline with an end dot. Renders a flat rule when the exercise has
/// no plottable history — never an invented curve.
struct AtriaStrengthSparkline: View {
    let values: [Double]

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            let height = max(proxy.size.height, 1)
            if values.count > 1 {
                let step = width / CGFloat(values.count - 1)
                Path { path in
                    path.move(to: CGPoint(x: 0, y: height - height * values[0]))
                    for index in values.indices.dropFirst() {
                        path.addLine(to: CGPoint(x: CGFloat(index) * step,
                                                 y: height - height * values[index]))
                    }
                }
                .stroke(AtriaStrengthPalette.amber,
                        style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                Circle()
                    .fill(AtriaStrengthPalette.amber)
                    .frame(width: 5, height: 5)
                    .position(x: width,
                              y: height - height * (values[values.count - 1]))
            } else {
                Capsule(style: .continuous)
                    .fill(.primary.opacity(0.14))
                    .frame(height: 2)
                    .position(x: width / 2, y: height / 2)
            }
        }
        .accessibilityHidden(true)
    }
}
