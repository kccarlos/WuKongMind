import SwiftUI

/// What the rest of the panel can ask of the composer, which owns its draft.
enum ComposerCommand {
    /// Put text in the box and focus it (a suggestion that fills the box).
    case fill(String)
    case focus
    case blur
    /// Empty the box and drop focus (a script repair was sent).
    case clearAndBlur
    /// Close the microphone and drop the words heard.
    case stopDictation
    /// Send as the composer's own send would: the microphone closes, the box empties on success.
    case send(String, attachedBlock: String?)
}

/// What the panel's send did with a prompt.
enum ComposerSendOutcome {
    case sent
    /// No provider is set up: the box keeps its text and loses focus.
    case needsProvider
    /// The run limit stopped it: nothing changes.
    case blocked
}

/// A question waiting for the Agent's composer (Siri's Ask a Forum, Home's
/// "Search this forum…"): the composer takes it and clears it. The app
/// model holds it without observing it.
///
/// It is also the way into the composer for the panel around it: the footer
/// registers `handler` while it is on screen, so the panel acts on the box
/// without reading the draft (a keystroke re-renders the footer alone).
@MainActor
final class ComposerDrafts: ObservableObject {
    @Published var goal = ""
    /// The draft of a footer that left the screen (History is open), for the next one.
    var parked = ""
    /// Set by the footer while it is on screen. Not published.
    var handler: ((ComposerCommand) -> Void)?

    func perform(_ command: ComposerCommand) {
        handler?(command)
    }
}
