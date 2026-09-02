import Foundation
import LimitrCore

enum AccountService: String, Codable, CaseIterable, Sendable {
    case codex
    case claude
}

struct AccountProfile: Codable, Identifiable, Equatable, Sendable {
    static let maximumPerService = 3

    var id: UUID
    var service: AccountService
    var name: String
    var codexHomePath: String? = nil
    /// Literal `CLAUDE_CONFIG_DIR` for this account. nil means the default `~/.claude`
    /// login, which must keep using the unhashed Keychain entry and must never have
    /// `CLAUDE_CONFIG_DIR` exported for it.
    var claudeConfigPath: String? = nil
    /// The account this service currently acts as: the one summarised in the menu-bar
    /// title, and the one new shells inherit via `ActiveAccountShell`. At most one per
    /// service; `UsageMonitor` maintains that invariant. Optional because Swift's
    /// synthesized `Decodable` does not substitute default values for absent keys — a
    /// non-optional `Bool` here would fail to decode every profile saved before this
    /// field existed.
    var isActive: Bool? = nil
    /// A removed account remains on disk so Limitr can bind the same account again without
    /// losing its isolated login, sessions, or account name.
    var isArchived: Bool? = nil

    var codexSessionsDirectory: URL? {
        codexHomePath.map { URL(fileURLWithPath: $0).appending(path: "sessions") }
    }

    var claudeConfigDirectory: URL? {
        claudeConfigPath.map { URL(fileURLWithPath: $0) }
    }

    static let defaults = [
        AccountProfile(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, service: .codex, name: "Personal", codexHomePath: FileManager.default.homeDirectoryForCurrentUser.appending(path: ".codex").path, isActive: true),
        AccountProfile(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, service: .claude, name: "Personal", isActive: true)
    ]
}

enum AccountProfileStorage {
    private static let key = "accounts"

    static func load() -> [AccountProfile] { loadStored() ?? AccountProfile.defaults }

    /// nil when nothing has ever been saved — which is how Limitr knows it is running for
    /// the first time, and therefore that it owes the user a look around their machine.
    static func loadStored() -> [AccountProfile]? {
        guard let data = AppDefaultsDomain.store().data(forKey: key),
              let profiles = try? JSONDecoder().decode([AccountProfile].self, from: data),
              !profiles.isEmpty else { return nil }
        return profiles
    }

    static func save(_ profiles: [AccountProfile]) {
        AppDefaultsDomain.store().set(try? JSONEncoder().encode(profiles), forKey: key)
    }

    static func newCodexHome(for id: UUID) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Limitr/Accounts/\(id.uuidString)/Codex")
    }

    static func newClaudeConfig(for id: UUID) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Limitr/Accounts/\(id.uuidString)/Claude")
    }

    /// Brings back account directories no saved profile points at any more.
    ///
    /// An account's identifier lives in exactly one mutable place — this list — while the
    /// login it names lives in two durable ones: the directory under Application Support,
    /// and, for Claude, a Keychain item whose service name is a hash of that directory's
    /// literal path. So the identifier is the credential's only address. Lose the row and
    /// adding the account back mints a *new* identifier, a new path, a new hash, and a
    /// login that has to be done again from nothing while the old one sits there valid.
    ///
    /// Recovery works only because the directory name is the identifier: the piece of
    /// state that went missing was also written down in the one place the credential
    /// cares about. Adopting under the original value is the whole point — see
    /// `OrphanedAccountScanner`.
    static func adoptingOrphans(
        into profiles: [AccountProfile],
        applicationSupport: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    ) -> [AccountProfile] {
        var adopted = profiles
        for orphan in OrphanedAccountScanner.scan(
            knownIDs: Set(profiles.map(\.id)),
            applicationSupport: applicationSupport
        ) {
            let service: AccountService = orphan.service == .claude ? .claude : .codex
            // Recorded either way; only visibility depends on there being room. A profile
            // Limitr knows about is one it never re-offers and never re-mints, and "Add
            // account" restores an archived row before creating a new one — so an account
            // parked here keeps its login instead of spending it.
            let visible = adopted.filter { $0.service == service && $0.isArchived != true }.count
            adopted.append(AccountProfile(
                id: orphan.id,
                service: service,
                name: orphan.email ?? "Recovered account",
                codexHomePath: service == .codex ? orphan.configPath : nil,
                claudeConfigPath: service == .claude ? orphan.configPath : nil,
                isActive: false,
                isArchived: visible >= AccountProfile.maximumPerService
            ))
        }
        return adopted
    }
}

/// Remembers which account the user picked by hand for each service.
///
/// Without this, "which account is active" has to be inferred from connectivity, and the
/// inference is wrong in exactly the moment that matters: an account reads as
/// disconnected for the whole of its sign-in, so a choice made just before signing in
/// was reassigned to the previously connected account a second or two later.
///
/// The identity is the part that matters, and it used to be missing. Recording only that
/// *a* choice had been made left `ActiveAccountResolver` protecting whichever account
/// happened to be active later, including one that had since been signed out — which is
/// what put a signed-out `CLAUDE_CONFIG_DIR` into every new terminal. Storing the account
/// itself is also what lets the resolver stand a choice down without losing it: the pick
/// survives a poll taken between choosing an account and signing into it.
enum ActiveAccountChoice {
    /// Predates recording *which* account was chosen. Still read, so an install that
    /// upgrades mid-flight keeps its standing choice instead of silently re-deriving one.
    private static let legacyKey = "explicitActiveServices"
    private static let key = "explicitActiveAccounts"

    static func chosen(_ service: AccountService) -> UUID? {
        (stored()[service.rawValue]).flatMap(UUID.init(uuidString:))
    }

    /// Whether the user has ever chosen for this service, from the key that recorded only
    /// that much. Callers pair it with the service's current active account to reconstruct
    /// a choice made before the identity was being written down.
    static func isExplicit(_ service: AccountService) -> Bool {
        Set(AppDefaultsDomain.store().stringArray(forKey: legacyKey) ?? []).contains(service.rawValue)
    }

    static func markExplicit(_ service: AccountService, account: UUID) {
        var services = Set(AppDefaultsDomain.store().stringArray(forKey: legacyKey) ?? [])
        if services.insert(service.rawValue).inserted {
            AppDefaultsDomain.store().set(Array(services).sorted(), forKey: legacyKey)
        }
        var accounts = stored()
        guard accounts[service.rawValue] != account.uuidString else { return }
        accounts[service.rawValue] = account.uuidString
        AppDefaultsDomain.store().set(accounts, forKey: key)
    }

    private static func stored() -> [String: String] {
        AppDefaultsDomain.store().dictionary(forKey: key) as? [String: String] ?? [:]
    }
}
