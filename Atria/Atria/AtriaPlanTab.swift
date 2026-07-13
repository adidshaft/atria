import Combine
import SwiftUI

/// The Plan tab — Atria's forward-looking guidance surface, promoted into the
/// bottom bar when the (still "Coming Soon") Assistant moved to a top-right
/// icon. v1 *composes* existing planning cards (weekly targets + routine /
/// habits) rather than relocating them, so nothing is lost and Today keeps its
/// own copies for now. Mirrors AtriaJournalTab: a plain group of cards that
/// `tabNavigation` lays out in its scrolling stack.
struct AtriaPlanTab: View {
    let store: SessionStore
    @StateObject private var projectionStore: AtriaPlanProjectionStore

    init(store: SessionStore) {
        self.store = store
        _projectionStore = StateObject(wrappedValue: AtriaPlanProjectionStore(store: store))
    }

    var body: some View {
        Group {
            AtriaWeeklyPlanCard(plan: projectionStore.weeklyPlan)
                .equatable()

            AtriaRoutineCard(store: store)
        }
    }
}

/// Keeps the Plan tab insulated from heart-rate, session, and dashboard churn.
/// Weekly guidance only changes when rollups change or the civil day rolls over.
@MainActor
final class AtriaPlanProjectionStore: ObservableObject {
    @Published private(set) var weeklyPlan: WeeklyPlan

    private weak var store: SessionStore?
    private var cancellables = Set<AnyCancellable>()

    init(store: SessionStore) {
        self.store = store
        weeklyPlan = store.currentWeeklyPlan()
        bind(to: store)
    }

    init(weeklyPlan: WeeklyPlan) {
        self.weeklyPlan = weeklyPlan
    }

    @discardableResult
    func refresh(_ next: WeeklyPlan) -> Bool {
        guard next != weeklyPlan else { return false }
        weeklyPlan = next
        return true
    }

    private func bind(to store: SessionStore) {
        store.$dailyRollupHistory
            .dropFirst()
            .sink { [weak self, weak store] _ in
                guard let self, let store else { return }
                self.refresh(store.currentWeeklyPlan())
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .NSCalendarDayChanged)
            .sink { [weak self] _ in
                guard let self, let store = self.store else { return }
                self.refresh(store.currentWeeklyPlan())
            }
            .store(in: &cancellables)
    }
}
