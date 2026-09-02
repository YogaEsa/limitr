import Foundation

public enum KeychainLookup: Sendable, Equatable {
    case found(String)
    case notFound
}

/// Whether a credential is where it is expected to be, including "could not tell".
///
/// The third case carries its weight for the same reason `ClaudeSignInState.unknown`
/// does: a locked or refusing Keychain is news about the reader, not about the account,
/// and collapsing it into `.absent` would sign every account out at once.
public enum CredentialPresence: Sendable, Equatable {
    case present
    case absent
    case unknown
}

public enum SecurityCLIError: LocalizedError, Equatable {
    /// The Keychain answered, and the answer was not "no such item": locked, denied,
    /// or otherwise refusing. Distinct from `.notFound` on purpose — telling someone
    /// to sign in again when their Keychain is merely locked sends them nowhere.
    case failed(status: Int32, message: String)
    /// `security` could not be run at all, or did not answer in time.
    case unavailable(String)

    public var errorDescription: String? {
        switch self {
        case .failed(let status, let message):
            message.isEmpty ? "The Keychain refused the request (status \(status))." : message
        case .unavailable(let reason):
            "The Keychain could not be reached: \(reason)"
        }
    }
}

/// Reads generic-password items through Apple's `security` tool.
///
/// Not `SecItemCopyMatching`. A Keychain item's access is anchored to the code that
/// created it, and Claude Code creates its credentials through `/usr/bin/security` —
/// which is therefore the one reader already on every item's ACL. An in-process
/// Security.framework call arrives as *Limitr*, so macOS prompts; worse, an ad-hoc
/// signed build has no Team ID, so "Always Allow" records a `cdhash:` partition that
/// every rebuild invalidates, and the prompt returns for good. Going through
/// `security` makes creator and reader the same binary, and there is no prompt.
///
/// The path is pinned rather than resolved through `PATH`: this reads credentials, so
/// a `security` planted earlier on the search path must not be able to intercept one.
public struct SecurityCLI: Sendable {
    public typealias Runner = @Sendable ([String]) throws -> ProcessResult

    public static let executable = URL(fileURLWithPath: "/usr/bin/security")

    /// Deliberately short. A healthy Keychain answers in well under 100ms, and a
    /// credential read may be followed by another spawn on the same poll.
    public static let timeout: TimeInterval = 5

    /// `errSecItemNotFound` as `security` surfaces it. Claude Code treats this as
    /// "read the file instead", so Limitr must not confuse it with a refusal.
    private static let itemNotFoundStatus: Int32 = 44

    private let run: Runner

    public init(run: @escaping Runner = SecurityCLI.spawn) {
        self.run = run
    }

    public static func spawn(_ arguments: [String]) throws -> ProcessResult {
        try ProcessRunner.run(executable: executable, arguments: arguments, timeout: timeout)
    }

    /// - Throws: `SecurityCLIError.failed` when the Keychain refused, `.unavailable`
    ///   when `security` could not be run or timed out. A missing item is `.notFound`.
    public func password(service: String, account: String) throws -> KeychainLookup {
        let result: ProcessResult
        do {
            result = try run(["find-generic-password", "-a", account, "-w", "-s", service])
        } catch {
            throw SecurityCLIError.unavailable(error.localizedDescription)
        }
        if result.status == 0 {
            // `-w` prints the value followed by exactly one newline. Trimming further
            // would corrupt a payload that legitimately ends in whitespace.
            var value = result.standardOutput
            if value.hasSuffix("\n") { value.removeLast() }
            return .found(value)
        }
        if result.status == Self.itemNotFoundStatus { return .notFound }
        throw SecurityCLIError.failed(
            status: result.status,
            message: result.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    /// Whether an item is there, without asking for its secret.
    ///
    /// An attribute-only lookup decrypts nothing, so it can never raise a Keychain
    /// prompt — not even for an item this app is not on the ACL of. Non-throwing by
    /// design: a Keychain that could not answer reports `.unknown`, which is the answer
    /// a caller deciding whether an account is signed in must not confuse with `.absent`.
    public func itemPresence(service: String, account: String) -> CredentialPresence {
        guard let result = try? run(["find-generic-password", "-a", account, "-s", service])
        else { return .unknown }
        if result.status == 0 { return .present }
        return result.status == Self.itemNotFoundStatus ? .absent : .unknown
    }

    /// Presence as a plain yes/no, for callers that only want a cheap hint and have
    /// nothing different to do about a Keychain that would not answer.
    public func itemExists(service: String, account: String) -> Bool {
        itemPresence(service: service, account: account) == .present
    }
}
