import Foundation

@main struct ScriptPreviewLogicTests {
    static var checks = 0
    static func check(_ condition: @autoclosure () -> Bool, _ reason: String) {
        checks += 1; precondition(condition(), reason)
    }

    static func main() {
        // A script taken from the middle of a long project must retain its
        // project timestamps; the middle of its rail is not project time 10.
        let excerpt = ScriptPreviewRange.bounds(start: 120, end: 140)!
        check(ScriptPreviewRange.time(at: 0, width: 360, in: excerpt) == 120, "Excerpt rail begins at absolute project time")
        check(ScriptPreviewRange.time(at: 180, width: 360, in: excerpt) == 130, "Excerpt midpoint keeps its project offset")
        check(ScriptPreviewRange.time(at: 360, width: 360, in: excerpt) == 140, "Excerpt rail ends at absolute project time")
        check(ScriptPreviewRange.time(at: -45, width: 360, in: excerpt) == 120, "Dragging outside the leading edge cannot leave the analysis")
        check(ScriptPreviewRange.time(at: 800, width: 360, in: excerpt) == 140, "Dragging outside the trailing edge cannot leave the analysis")

        // A cue may partially overlap a view's analysis interval, especially
        // when reading an edited draft. Replay must never play outside it.
        check(ScriptPreviewRange.clipped(118...123, to: excerpt) == 120...123, "Replay clamps an earlier selected cue")
        check(ScriptPreviewRange.clipped(138...155, to: excerpt) == 138...140, "Replay clamps a later selected cue")
        check(ScriptPreviewRange.clipped(0...200, to: excerpt) == excerpt, "A containing selection uses only the excerpt")
        check(ScriptPreviewRange.clipped(0...119, to: excerpt) == nil, "A disjoint cue has no playable selection")
        check(ScriptPreviewRange.clipped(130...130, to: excerpt) == nil, "A zero-duration cue cannot start playback")
        check(ScriptPreviewRange.clipped(nil, to: excerpt) == nil, "No selected text produces no replay range")

        let marker = ScriptPreviewRange.fraction(123.125, in: excerpt)
        let recovered = ScriptPreviewRange.time(at: marker * 405, width: 405, in: excerpt)
        check(abs(recovered - 123.125) < 0.000001, "Resizing the preview preserves exact cue alignment")
        check(ScriptPreviewRange.fraction(0, in: excerpt) == 0, "Earlier segments cannot draw beyond the rail")
        check(ScriptPreviewRange.fraction(200, in: excerpt) == 1, "Later segments cannot draw beyond the rail")
        check(ScriptPreviewRange.time(at: .nan, width: 360, in: excerpt) == 120, "An invalid gesture cannot send NaN to AVPlayer")
        check(ScriptPreviewRange.time(at: 100, width: 0, in: excerpt) == 120, "A layout transition cannot divide by zero")
        check(ScriptPreviewRange.bounds(start: 5, end: 5) == nil, "Zero-length analyses are unplayable")
        check(ScriptPreviewRange.bounds(start: -.infinity, end: 5) == nil, "Non-finite source times are unplayable")
        check(ScriptPreviewRange.bounds(start: 0, end: .infinity) == nil, "Non-finite end times are unplayable")
        print("Script preview range tests passed (\(checks) assertions).")
    }
}
