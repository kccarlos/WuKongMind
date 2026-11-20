import SwiftUI

// MARK: - Read aloud

/// Reads a summary aloud with the speech engines; tapping again pauses.
struct ReadAloudButton: View {
    @ObservedObject var podcast: PodcastController
    let id: String
    let title: String
    let text: String
    var compact = false

    var body: some View {
        let reading = podcast.isReadingAloud(id)
        Button {
            DCHaptics.tap()
            podcast.readAloud(id: id, title: title, text: text)
        } label: {
            if compact {
                Image(systemName: reading ? "pause.circle" : "speaker.wave.2")
            } else {
                Label(reading ? "Pause" : "Listen", systemImage: reading ? "pause.circle" : "speaker.wave.2")
            }
        }
        .accessibilityLabel(reading ? Text("Pause") : Text("Read aloud", comment: "Button: reads the summary aloud"))
        .accessibilityIdentifier("readAloud-\(id)")
    }
}
