import SwiftUI

/// Settings → Lock Screen & Widgets (2026-09-24, owner: "people should be able
/// to choose what they see … permanently look at live HR in the island or not
/// … keep the UI very simple, very iOS native").
///
/// Every control writes the one store the surface reads:
/// Live Activity → `AtriaGlanceSettings` (app group, read by the coordinator
/// and the widget extension); widget rings → `AtriaRingLayoutSection`'s own
/// store (the same one Today uses).
struct AtriaGlanceSettingsView: View {
    @State private var mode = AtriaGlanceSettings.liveActivityMode()
    @State private var items = AtriaGlanceSettings.liveItems()

    var body: some View {
        Form {
            previewSection
            modeSection
            itemsSection
            widgetsSection
        }
        .navigationTitle("Lock Screen & Widgets")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: mode) { _, newValue in
            AtriaGlanceSettings.setLiveActivityMode(newValue)
        }
        .onChange(of: items) { _, newValue in
            AtriaGlanceSettings.setLiveItems(newValue)
        }
    }

    private var previewSection: some View {
        Section {
            AtriaGlancePreview(mode: mode, items: items)
                .listRowInsets(EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16))
                .listRowBackground(Color.clear)
        }
    }

    private var modeSection: some View {
        Section {
            Picker("Live Activity", selection: $mode) {
                ForEach(AtriaGlanceSettings.LiveActivityMode.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .listRowSeparator(.hidden)
        } header: {
            Text("Live Activity")
        } footer: {
            Text(mode.detail)
        }
    }

    private var itemsSection: some View {
        Section("Next to heart rate") {
            ForEach(AtriaGlanceSettings.LiveItem.allCases) { item in
                Toggle(isOn: binding(for: item)) {
                    Label(item.title, systemImage: item.systemImage)
                }
            }
        }
        .disabled(mode == .off)
    }

    private var widgetsSection: some View {
        Section {
            NavigationLink {
                Form { AtriaRingLayoutSection() }
                    .navigationTitle("Rings")
                    .navigationBarTitleDisplayMode(.inline)
            } label: {
                Label("Rings and order", systemImage: "circle.circle")
            }
            LabeledContent {
                Text("Hold Home Screen → Edit → Add Widget")
                    .multilineTextAlignment(.trailing)
            } label: {
                Label("Add a widget", systemImage: "plus.square.on.square")
            }
            .font(.subheadline)
        } header: {
            Text("Widgets")
        } footer: {
            Text("Widgets and Today share the same rings.")
        }
    }

    private func binding(for item: AtriaGlanceSettings.LiveItem) -> Binding<Bool> {
        Binding(
            get: { items.contains(item) },
            set: { on in
                if on { items.insert(item) } else { items.remove(item) }
            }
        )
    }
}

/// A drawn preview of the Lock Screen Live Activity with the current choices.
/// Sample numbers, clearly a preview; it only shows layout, never data.
private struct AtriaGlancePreview: View {
    let mode: AtriaGlanceSettings.LiveActivityMode
    let items: Set<AtriaGlanceSettings.LiveItem>

    var body: some View {
        VStack(spacing: 10) {
            if mode == .off {
                Label("Live Activity off", systemImage: "rectangle.slash")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                island
                lockScreenCard
            }
            Text("Preview")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(mode == .off
                            ? "Live Activity off"
                            : "Preview: heart rate\(items.isEmpty ? "" : " with " + items.map(\.title).sorted().joined(separator: ", "))")
    }

    /// Compact Dynamic Island: always heart rate, which is what "Always"
    /// keeps on screen.
    private var island: some View {
        HStack {
            Image(systemName: "heart.fill").foregroundStyle(.red)
            Spacer()
            Text("72").font(.subheadline.weight(.bold)).monospacedDigit()
        }
        .font(.subheadline)
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .frame(width: 180, height: 34)
        .background(.black, in: Capsule())
    }

    private var lockScreenCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(mode == .workouts ? "Workout" : "Atria", systemImage: mode == .workouts ? "figure.run" : "heart.fill")
                    .font(.subheadline.weight(.bold))
                Spacer()
                Label("Live", systemImage: "circle.fill")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.green)
                if items.contains(.battery) {
                    Label("64%", systemImage: "battery.75percent")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .labelStyle(.titleAndIcon)
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Image(systemName: "heart.fill").font(.caption.weight(.black))
                    Text("72").font(.system(size: 30, weight: .black, design: .rounded))
                    Text("BPM").font(.system(size: 9, weight: .bold, design: .rounded))
                }
                .foregroundStyle(.red)
                if items.contains(.zone) {
                    Text("Zone 2")
                        .font(.headline.weight(.black))
                        .foregroundStyle(.cyan)
                }
                Spacer()
            }
            if items.contains(.steps) {
                Label("6,420 / 10,000", systemImage: "figure.walk")
                    .font(.caption.weight(.bold).monospacedDigit())
                    .foregroundStyle(.white, .mint)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.black, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}
