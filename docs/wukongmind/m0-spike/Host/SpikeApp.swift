import SwiftUI

/// Host app for the M0 spike tests. It only provides a window the test web views attach to.
@main
struct SpikeApp: App {
    var body: some Scene {
        WindowGroup {
            Text("WukongMind M0 spike host")
        }
    }
}
