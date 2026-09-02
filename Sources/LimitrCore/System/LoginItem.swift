import Foundation
import ServiceManagement

public enum LoginItemError: LocalizedError, Equatable {
    /// Registered, but switched off by the user in System Settings.
    case requiresApproval
    /// No app bundle for Service Management to register.
    case unavailable
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .requiresApproval: "Limitr is switched off in System Settings › General › Login Items."
        case .unavailable: "Opening at login needs Limitr to be running from an app bundle."
        case .failed(let reason): "Opening at login could not be changed: \(reason)"
        }
    }
}

/// Whether Limitr starts itself when the Mac is logged into.
///
/// A monitor is worth having only if it is running before the thing it monitors, and a
/// menu-bar app the user has to remember to launch is one they stop having open. This is
/// the modern `SMAppService` registration rather than a login-items plist, so the toggle
/// and System Settings describe one fact.
///
/// The Service Management calls are injected so the state mapping — the part with real
/// decisions in it — can be tested without registering anything on the machine running
/// the tests.
public struct LoginItem: Sendable {

    public enum State: Equatable, Sendable {
        case enabled
        case disabled
        /// The registration exists but the user switched it off themselves. Registering
        /// again does not lift that; only they can.
        case requiresApproval
        /// Nothing registrable — `swift run`, or a binary outside its bundle.
        case unavailable
    }

    private let status: @Sendable () -> SMAppService.Status
    private let register: @Sendable () throws -> Void
    private let unregister: @Sendable () throws -> Void

    public init(
        status: @escaping @Sendable () -> SMAppService.Status = { SMAppService.mainApp.status },
        register: @escaping @Sendable () throws -> Void = { try SMAppService.mainApp.register() },
        unregister: @escaping @Sendable () throws -> Void = { try SMAppService.mainApp.unregister() }
    ) {
        self.status = status
        self.register = register
        self.unregister = unregister
    }

    public var state: State {
        switch status() {
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notFound: .unavailable
        case .notRegistered: .disabled
        @unknown default: .disabled
        }
    }

    public var isEnabled: Bool { state == .enabled }

    /// - Throws: `LoginItemError` when the state cannot be reached, so the caller can say
    ///   which of the two reasons it was — telling someone to check System Settings when
    ///   the real problem is an unbundled build sends them nowhere.
    public func setEnabled(_ enabled: Bool) throws {
        switch (state, enabled) {
        case (.unavailable, _):
            throw LoginItemError.unavailable
        case (.requiresApproval, true):
            throw LoginItemError.requiresApproval
        case (.enabled, true), (.disabled, false):
            // Already where it was asked to be. Calling through would be a no-op at best
            // and an error at worst.
            return
        case (_, true):
            do { try register() } catch { throw LoginItemError.failed(error.localizedDescription) }
        case (_, false):
            do { try unregister() } catch { throw LoginItemError.failed(error.localizedDescription) }
        }
    }

    /// Where the user goes to lift their own refusal. Nothing else can.
    public static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
