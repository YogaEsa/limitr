import Foundation

/// What the panel asks before handing a service to a different account.
///
/// In Core, and deliberately free of every app type, because the part worth pinning down
/// is the wording rather than the sheet: a switch reaches new terminals and the next
/// command in terminals already open, and stops there. A `claude` or `codex` that is
/// already running read its credential at exec time and keeps spending the old account
/// until it is restarted, so a message that implies otherwise sends someone back to a
/// session they believe has moved. `LimitrCoreTests` is also the only test target, which
/// is the second reason the decision lives here and only the sheet lives in the view.
public struct ActivationPrompt: Equatable, Sendable {
    /// Fixed copy, exposed statically as well because a dialog's button needs a label even
    /// in the instant its binding still reports no pending account.
    public static let confirmTitle = "Make Active"

    public let title: String
    public let message: String
    public let confirmTitle: String

    /// The prompt for making `accountName` the active account, or nil when the click is not
    /// a switch at all.
    ///
    /// - Parameter isAlreadyActive: clicking the account that already holds the service is
    ///   how the user says "stop reassigning this" — `UsageMonitor.setActive` marks the
    ///   choice explicit before it does anything else. Confirming that would be asking
    ///   about a change that is not being made.
    public static func forActivating(
        accountName: String,
        serviceLabel: String,
        isAlreadyActive: Bool
    ) -> ActivationPrompt? {
        guard !isAlreadyActive else { return nil }
        let trimmed = accountName.trimmingCharacters(in: .whitespacesAndNewlines)
        // The row's name is an editable text field, so it can be blank at the moment the
        // star is clicked. Naming nothing beats quoting nothing.
        let subject = trimmed.isEmpty ? "this" : "\"\(trimmed)\""
        return ActivationPrompt(
            title: "Make \(subject) the active \(serviceLabel) account?",
            // Both facts, in as few words as carry them: the switch reaches new terminals
            // and the next command in open ones, and it does not reach a session that is
            // already running. Length is the only thing deciding how tall the inline bar
            // gets, and a confirmation that fills the panel reads as an error.
            message: """
            New terminals, and the next command in open ones, use this account. \
            A running session keeps its old account until restarted.
            """,
            confirmTitle: Self.confirmTitle
        )
    }
}
