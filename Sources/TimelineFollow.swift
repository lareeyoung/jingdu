import Foundation

/// Reveals a moving or explicitly selected playhead without recentering each frame.
/// A manual scroll alone never requests a reveal; zoom and resize own their anchor.
enum TimelineFollow {
    static func targetOrigin(currentTime: Double, duration: Double,
                             currentOrigin: Double, contentWidth: Double,
                             viewportWidth: Double, enabled: Bool,
                             timeChanged: Bool, becameEnabled: Bool,
                             geometryChanged: Bool, magnifying: Bool = false) -> Double? {
        guard enabled, timeChanged || becameEnabled,
              !geometryChanged, !magnifying,
              currentTime.isFinite, duration.isFinite, duration > 0,
              currentOrigin.isFinite, contentWidth.isFinite, contentWidth > 0,
              viewportWidth.isFinite, viewportWidth > 1,
              contentWidth > viewportWidth else { return nil }

        let maximumOrigin = contentWidth - viewportWidth
        let origin = min(maximumOrigin, max(0, currentOrigin))
        let position = min(1, max(0, currentTime / duration)) * contentWidth
        let localPosition = position - origin
        // Only reveal once the playhead reaches the visible edge. Clicking a
        // visible timeline location must not move that location under the pointer.
        let inset = min(80, viewportWidth * 0.12)
        let proposed: Double
        if localPosition < 0 {
            proposed = position - (viewportWidth - inset)
        } else if localPosition >= viewportWidth - 1 {
            proposed = position - inset
        } else {
            return nil
        }
        let result = min(maximumOrigin, max(0, proposed))
        return abs(result - currentOrigin) > 0.1 ? result : nil
    }
}
