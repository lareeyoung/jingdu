import Foundation

// swiftc Sources/TimelineFollow.swift Tests/TimelineFollowTests.swift -o /tmp/jingdu-timeline-follow-tests && /tmp/jingdu-timeline-follow-tests
@main struct TimelineFollowTests {
    private static var checks = 0

    private static func check(_ condition: @autoclosure () -> Bool, _ reason: String) {
        checks += 1
        precondition(condition(), reason)
    }

    private static func origin(time: Double = 51, duration: Double = 100,
                               current: Double = 1000, content: Double = 4000,
                               viewport: Double = 1000, enabled: Bool = true,
                               timeChanged: Bool = true, becameEnabled: Bool = false,
                               geometryChanged: Bool = false, magnifying: Bool = false) -> Double? {
        TimelineFollow.targetOrigin(currentTime: time, duration: duration,
                                    currentOrigin: current, contentWidth: content,
                                    viewportWidth: viewport, enabled: enabled,
                                    timeChanged: timeChanged, becameEnabled: becameEnabled,
                                    geometryChanged: geometryChanged, magnifying: magnifying)
    }

    static func main() {
        check(origin() == 1960, "Forward playback pages ahead with room for the next frames")
        check(origin(time: 24) == 40, "Backward seeking reveals the playhead near the right of the viewport")
        check(origin(time: 30) == nil, "A visible playhead does not recenter on every frame")
        check(origin(time: 25) == nil, "The visible leading edge stays put")
        check(origin(time: 25.1) == nil, "Clicking a visible cue close to the edge does not move it")
        check(origin(time: 49.9) == nil, "The viewport remains still until the trailing edge")
        check(origin(time: 50) == 1920, "Playback advances at the trailing edge")
        check(origin(time: 0) == 0, "Seeking the start cannot scroll before the document")
        check(origin(time: 100) == 3000, "Seeking the end stops at the document end")
        check(origin(time: -20) == 0, "Negative player times clamp to the start")
        check(origin(time: 120) == 3000, "Times beyond duration clamp to the end")
        check(origin(time: 100, current: 3000) == nil, "The last frame does not repeatedly scroll at the end")
        check(origin(time: 0, current: 0) == nil, "The first frame does not repeatedly scroll at the start")
        check(origin(time: 50, current: 0, content: 400, viewport: 100) == 188,
              "Small windows use a proportional reveal inset")

        check(origin(enabled: false) == nil, "The master switch prevents following while playing")
        check(origin(enabled: false, becameEnabled: true) == nil, "A disabled switch always wins over stale state")
        check(origin(timeChanged: false) == nil, "Manual scrolling at a paused time never snaps back")
        check(origin(timeChanged: false, becameEnabled: true) == 1960,
              "Switching follow on reveals the current paused position")
        check(origin(geometryChanged: true) == nil, "Zoom and resize keep their anchor when time also changes")
        check(origin(timeChanged: false, becameEnabled: true, geometryChanged: true) == nil,
              "A simultaneous switch and geometry change preserves the pointer anchor")
        check(origin(magnifying: true) == nil, "Playback updates between pinch events do not fight the gesture")

        let firstPage = origin(time: 25, current: 0)!
        check(firstPage == 920, "First crossing reveals a new page")
        check(origin(time: 25.025, current: firstPage) == nil,
              "The next playback tick stays on the new page")
        check(origin(time: 25.025, current: 2000, timeChanged: false) == nil,
              "Manually browsing another region while paused remains possible")
        check(origin(time: 25.025, current: 2000, timeChanged: false, becameEnabled: true) != nil,
              "Reenabling follow returns from a manually browsed region")

        check(origin(content: 1000) == nil, "Fit-to-width needs no scrolling")
        check(origin(content: 500) == nil, "A shorter document needs no scrolling")
        check(origin(duration: 0) == nil, "An unloaded project cannot divide by zero")
        check(origin(duration: -1) == nil, "Invalid project duration disables following")
        check(origin(viewport: 0) == nil, "Hidden viewports do not scroll")
        check(origin(viewport: 1) == nil, "Transient one-pixel layout does not scroll")
        check(origin(content: -1) == nil, "Invalid document width does not scroll")
        for invalid in [Double.nan, Double.infinity, -Double.infinity] {
            check(origin(time: invalid) == nil, "Non-finite time is rejected")
            check(origin(duration: invalid) == nil, "Non-finite duration is rejected")
            check(origin(current: invalid) == nil, "Non-finite origin is rejected")
            check(origin(content: invalid) == nil, "Non-finite document width is rejected")
            check(origin(viewport: invalid) == nil, "Non-finite viewport width is rejected")
        }
        print("Timeline follow tests passed (\(checks) assertions).")
    }
}
