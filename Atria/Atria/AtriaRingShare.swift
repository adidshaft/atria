import Foundation

/// Item-driven route into the shared, full-height Atria composer. The ring
/// launcher intentionally reuses the same 9:16 canvas, accent/photo/camera
/// controls, download behavior, and share renderer as the main Share action.
struct AtriaRingShareRoute: Identifiable {
    let id = UUID()
    let snapshot: AtriaShareSnapshot
}
