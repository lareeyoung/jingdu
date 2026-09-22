import SwiftUI

// The macOS 27 SDK also exports a State macro whose plugin is absent from
// Command Line Tools. Resolve the stable property wrapper explicitly; this
// keeps our macOS 14 app buildable without requiring the full Xcode app.
typealias JingduState<Value> = SwiftUI.State<Value>
