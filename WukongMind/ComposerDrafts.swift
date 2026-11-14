import SwiftUI

/// A question waiting for the Agent's composer (Siri's Ask a Forum, Home's
/// "Search this forum…"): the composer takes it and clears it. The app
/// model holds it without observing it.
@MainActor
final class ComposerDrafts: ObservableObject {
    @Published var goal = ""
}
