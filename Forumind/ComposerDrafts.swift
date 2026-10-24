import SwiftUI

/// The unsent text of the composers: This topic's chat question, a new Ask
/// the forum question, and a follow-up to a finished run. Every keystroke
/// publishes here, so only the Ask box and the composers observe it; the
/// app model holds it without observing it.
@MainActor
final class ComposerDrafts: ObservableObject {
    @Published var chat = ""
    @Published var goal = ""
    @Published var followUp = ""
}
