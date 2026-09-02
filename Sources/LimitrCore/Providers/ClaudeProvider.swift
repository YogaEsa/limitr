import Foundation
import Security

public enum ClaudeProviderError: LocalizedError {
    case credentialsMissing
    case invalidCredentials
    case keychainUnavailable(String)
    case loginRequired
    case rateLimited
    case requestFailed(Int)
    case responseInvalid

    public var errorDescription: String? {
        switch self {
        case .credentialsMissing: "Claude credentials were not found. Run `claude login`."
        case .invalidCredentials: "Claude credentials could not be read."
        case .keychainUnavailable(let reason): "Claude credentials are in the Keychain, which did not answer: \(reason)"
        case .loginRequired: "Claude login has expired. Run `claude login`."
        case .rateLimited: "Claude rate-limit endpoint asked Limitr to back off."
        case .requestFailed(let status): "Claude usage request failed (HTTP \(status))."
        case .responseInvalid: "Claude returned an unrecognized usage response."
        }
    }

    /// Whether this failure happened before any request reached Anthropic.
    ///
    /// The usage endpoint budgets roughly 28-30 requests per identity per rolling
    /// hour, so retry cadence has to be spent carefully — but a credential that could
    /// not be read throws while the request is still being assembled and costs none of
    /// that budget. Callers use this to retry a local failure quickly without touching
    /// the backoff that protects the remote one.
    public var isLocal: Bool {
        switch self {
        case .credentialsMissing, .invalidCredentials, .keychainUnavailable: true
        case .loginRequired, .rateLimited, .requestFailed, .responseInvalid: false
        }
    }
}

/// One poll's answer: the rolling windows, plus the extra-usage meter when the account
/// has one switched on.
public struct ClaudeUsage: Equatable, Sendable {
    public let windows: [UsageWindow]
    public let extraUsage: ExtraUsage?

    public init(windows: [UsageWindow], extraUsage: ExtraUsage? = nil) {
        self.windows = windows
        self.extraUsage = extraUsage
    }
}

public struct ClaudeProvider {
    private let session: URLSession
    private let fileManager: FileManager
    private let accountID: String
    private let accountName: String
    private let configDirectory: String?
    private let environment: [String: String]
    private let security: SecurityCLI

    /// - Parameter configDirectory: the literal `CLAUDE_CONFIG_DIR` for this account,
    ///   or nil for the default `~/.claude` login. Passed through to `ClaudeKeychain`
    ///   unmodified — see the hashing note there.
    public init(
        accountID: String = "default",
        accountName: String = "Default",
        configDirectory: String? = nil,
        session: URLSession = .shared,
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        security: SecurityCLI = SecurityCLI()
    ) {
        self.accountID = accountID
        self.accountName = accountName
        self.configDirectory = configDirectory
        self.session = session
        self.fileManager = fileManager
        self.environment = environment
        self.security = security
    }

    var keychainServiceName: String { ClaudeKeychain.serviceName(configDirectory: configDirectory) }

    var keychainServiceNames: [String] {
        ClaudeKeychain.serviceNames(
            configDirectory: configDirectory,
            environment: environment,
            fileManager: fileManager
        )
    }

    static func credentialsFileURL(configDirectory: String?, fileManager: FileManager = .default) -> URL {
        let base = configDirectory.map { URL(fileURLWithPath: $0) }
            ?? fileManager.homeDirectoryForCurrentUser.appending(path: ".claude")
        return base.appending(path: ".credentials.json")
    }

    public func fetch(now: Date = .now) async throws -> ClaudeUsage {
        // Keychain access shells out, and the first `claude --version` call waits on a
        // child process. Keep both off the caller's actor so polling never stalls the UI.
        let services = keychainServiceNames
        let account = ClaudeKeychain.account(environment: environment)
        let fallback = Self.credentialsFileURL(configDirectory: configDirectory, fileManager: fileManager)
        let security = security
        let (token, version) = try await Task.detached(priority: .utility) {
            (
                try Self.credentialsToken(
                    serviceNames: services,
                    account: account,
                    fallback: fallback,
                    security: security
                ),
                Self.cachedCLIVersion
            )
        }.value
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("claude-code/\(version)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 { throw ClaudeProviderError.loginRequired }
        if status == 429 { throw ClaudeProviderError.rateLimited }
        guard (200...299).contains(status) else { throw ClaudeProviderError.requestFailed(status) }
        return try Self.usage(from: data, accountID: accountID, accountName: accountName)
    }

    /// Maps one usage payload onto the shared model.
    ///
    /// Separate from `fetch` so the mapping can be exercised without a network stub — it
    /// is the half of this provider that changes when Anthropic changes the response.
    static func usage(from data: Data, accountID: String, accountName: String) throws -> ClaudeUsage {
        let payload = try JSONDecoder.claude.decode(ClaudeUsageResponse.self, from: data)
        let windows: [(String, ClaudeWindow?)] = [("five_hour", payload.fiveHour), ("seven_day", payload.sevenDay), ("seven_day_opus", payload.sevenDayOpus), ("seven_day_sonnet", payload.sevenDaySonnet)]
        let result = windows.compactMap { label, value -> UsageWindow? in
            guard let value, let resetsAt = value.resetsAt else { return nil }
            return UsageWindow(source: .claude, accountID: accountID, accountName: accountName, label: label, usedPercent: value.utilization ?? 0, resetsAt: resetsAt,
                               windowMinutes: label == "five_hour" ? 300 : 10_080, staleness: .fresh)
        }
        guard !result.isEmpty else { throw ClaudeProviderError.responseInvalid }
        // An account that has never switched extra usage on still gets the object back,
        // with every figure null. Reporting that as a meter would put an empty bar on the
        // panel for almost everybody.
        let extra = payload.extraUsage.flatMap { $0.isEnabled == true ? ExtraUsage(monthlyLimit: $0.monthlyLimit, usedCredits: $0.usedCredits, utilization: $0.utilization) : nil }
        return ClaudeUsage(windows: result, extraUsage: extra)
    }

    /// Reads this profile's OAuth token, preferring the reader Claude Code itself uses.
    ///
    /// `security` first and in-process second, not the other way round: see `SecurityCLI`
    /// for why the in-process call is the one that makes macOS prompt. It is kept only
    /// for a machine where `security` could not be run at all — never as a routine
    /// second try, and never when the Keychain answered with a refusal, since prompting
    /// there would ask the user to approve a read that is going to fail anyway.
    static func credentialsToken(
        serviceNames: [String],
        account: String,
        fallback: URL,
        security: SecurityCLI
    ) throws -> String {
        var refusal: SecurityCLIError?
        var unreachable: SecurityCLIError?

        for service in serviceNames {
            do {
                // `.notFound` is Claude's own signal that this store is empty, so it
                // moves on to the next name rather than ending the search.
                guard case .found(let value) = try security.password(service: service, account: account)
                else { continue }
                guard let token = Self.token(in: value) else { throw ClaudeProviderError.invalidCredentials }
                return token
            } catch let error as SecurityCLIError {
                switch error {
                case .failed: refusal = error
                case .unavailable: unreachable = error
                }
            }
        }

        if unreachable != nil {
            for service in serviceNames {
                if let value = Self.inProcessValue(service: service, account: account),
                   let token = Self.token(in: value) { return token }
            }
        }

        if let data = try? Data(contentsOf: fallback),
           let value = String(data: data, encoding: .utf8),
           let token = Self.token(in: value) { return token }

        // Claude Code stores credentials in the Keychain on macOS and only writes the
        // plaintext file on other platforms, so reaching here after a refusal almost
        // always means the Keychain was the problem — reporting it as "not found"
        // would send the user to re-run a login they do not need.
        if let error = refusal ?? unreachable {
            throw ClaudeProviderError.keychainUnavailable(error.localizedDescription)
        }
        throw ClaudeProviderError.credentialsMissing
    }

    private static func inProcessValue(service: String, account: String) -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrAccount: account,
            kSecAttrService: service,
            kSecMatchLimit: kSecMatchLimitOne,
            kSecReturnData: true
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Resolved at most once per launch. `static let` is lazy and thread-safe, so
    /// polling N accounts every 180s no longer spawns N `claude --version` processes.
    private static let cachedCLIVersion: String = {
        // `env` rather than a pinned path: this resolves the user's own `claude`, which
        // is legitimately wherever their installer put it. Nothing secret passes here.
        guard let result = try? ProcessRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: ["claude", "--version"],
            timeout: 10
        ), result.status == 0 else { return "unknown" }
        return result.standardOutput.split(whereSeparator: { $0.isWhitespace }).last.map(String.init) ?? "unknown"
    }()

    private static func token(in value: String) -> String? {
        guard let data = value.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return findToken(object)
    }

    private static func findToken(_ object: Any) -> String? {
        if let dictionary = object as? [String: Any] {
            for key in ["accessToken", "access_token"] { if let token = dictionary[key] as? String { return token } }
            return dictionary.values.lazy.compactMap(findToken).first
        }
        if let array = object as? [Any] { return array.lazy.compactMap(findToken).first }
        return nil
    }
}

private struct ClaudeUsageResponse: Decodable {
    let fiveHour: ClaudeWindow?; let sevenDay: ClaudeWindow?; let sevenDayOpus: ClaudeWindow?; let sevenDaySonnet: ClaudeWindow?
    let extraUsage: ClaudeExtraUsage?
    enum CodingKeys: String, CodingKey { case fiveHour = "five_hour", sevenDay = "seven_day", sevenDayOpus = "seven_day_opus", sevenDaySonnet = "seven_day_sonnet", extraUsage = "extra_usage" }
}
private struct ClaudeExtraUsage: Decodable {
    let isEnabled: Bool?; let monthlyLimit: Double?; let usedCredits: Double?; let utilization: Double?
    enum CodingKeys: String, CodingKey { case isEnabled = "is_enabled", monthlyLimit = "monthly_limit", usedCredits = "used_credits", utilization }
}
private struct ClaudeWindow: Decodable { let utilization: Double?; let resetsAt: Date?; enum CodingKeys: String, CodingKey { case utilization; case resetsAt = "resets_at" } }
private extension JSONDecoder { static var claude: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d } }
