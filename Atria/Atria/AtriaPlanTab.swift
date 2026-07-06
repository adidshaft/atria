import SwiftUI

/// The Plan tab — Atria's forward-looking guidance surface, promoted into the
/// bottom bar when the (still "Coming Soon") Assistant moved to a top-right
/// icon. v1 *composes* existing planning cards (weekly targets + routine /
/// habits) rather than relocating them, so nothing is lost and Today keeps its
/// own copies for now. Mirrors AtriaJournalTab: a plain group of cards that
/// `tabNavigation` lays out in its scrolling stack.
struct AtriaPlanTab: View {
    @ObservedObject var store: SessionStore

    private var weeklyPlan: WeeklyPlan {
        WeeklyPlanStore().currentPlan(rollups: store.dailyRollupHistory)
    }

    var body: some View {
        Group {
            AtriaWeeklyPlanCard(plan: weeklyPlan)
                .equatable()

            AtriaRoutineCard(store: store)
        }
    }
}
