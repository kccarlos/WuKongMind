import SwiftUI

/// Host app for the M4 spike tests. It only provides a window the test web views attach to.
@main
struct SpikeApp: App {
    var body: some Scene {
        WindowGroup {
            Text("WukongMind M4 spike host")
        }
    }
}
