import SwiftUI
import LimitrCore

enum DetectionState: Equatable {
    case idle
    case scanning
    case done([DetectedService])

    var results: [DetectedService]? {
        if case .done(let services) = self { return services }
        return nil
    }
}

extension DetectedService {
    var service: AccountService { source == .codex ? .codex : .claude }
}

/// The first thing a new user sees, and the answer to "do I have to sign in again?".
///
/// Someone installing Limitr has almost certainly been using at least one of these CLIs
/// already. Asking them to log in a second time would be asking them to prove something
/// the machine can already see, so the opening move is to go and look.
struct DetectionCard: View {
    let state: DetectionState
    let canInstallShellIntegration: Bool
    @Binding var installsShellIntegration: Bool
    let detect: () -> Void
    let adopt: () -> Void
    let signIn: (AccountService) -> Void
    /// Only offered when there is already something to go back to; a first run with nothing
    /// signed in would skip to an empty panel.
    let skip: (() -> Void)?

    var body: some View {
        VStack(spacing: 12) {
            switch state {
            case .idle: invitation
            case .scanning: progress
            case .done(let services): results(services)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .padding(.horizontal, 12)
        .card(padding: 0)
    }

    // MARK: - Before

    private var invitation: some View {
        VStack(spacing: 10) {
            Image(systemName: "sparkle.magnifyingglass")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.secondary)
            VStack(spacing: 3) {
                Text("Find your existing logins")
                    .font(.subheadline.weight(.semibold))
                Text("Limitr reads the Claude Code and Codex accounts already on this Mac. You will not have to sign in again.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if canInstallShellIntegration { shellToggle }
            HStack(spacing: 8) {
                Button("Detect", action: detect)
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                if let skip {
                    Button("Skip", action: skip).controlSize(.large)
                }
            }
        }
    }

    /// Drawn rather than `Toggle(.checkbox)`: that style is an AppKit control, and the rest
    /// of this panel is custom SwiftUI, so the native one arrives with its own metrics and
    /// its own idea of the accent.
    private var shellToggle: some View {
        Button { installsShellIntegration.toggle() } label: {
            HStack(spacing: 6) {
                Image(systemName: installsShellIntegration ? "checkmark.square.fill" : "square")
                    .font(.system(size: 12))
                    .foregroundStyle(installsShellIntegration ? Color.accentColor : Color.secondary)
                Text("Use the active account in new terminals")
                    .font(.caption)
                    .foregroundStyle(.primary)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help("Adds one line to your shell profile that points new terminals at whichever account is active. You can remove it at any time.")
        .accessibilityAddTraits(installsShellIntegration ? [.isButton, .isSelected] : .isButton)
        .padding(.top, 2)
    }

    // MARK: - During

    private var progress: some View {
        VStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("Looking for Claude Code and Codex…")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Reading your shell settings, in case either lives somewhere custom.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }

    // MARK: - After

    private var foundAnything: Bool {
        state.results?.contains { !$0.logins.isEmpty } ?? false
    }

    @ViewBuilder
    private func results(_ services: [DetectedService]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(services) { service in
                ServiceResult(service: service) { signIn(service.service) }
            }

            if canInstallShellIntegration && foundAnything {
                shellToggle
            }

            HStack(spacing: 8) {
                if foundAnything {
                    Button("Connect", action: adopt)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.regular)
                }
                Button(foundAnything ? "Scan again" : "Try again", action: detect)
                    .controlSize(.regular)
                if let skip, !foundAnything {
                    Button("Skip", action: skip).controlSize(.regular)
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ServiceResult: View {
    let service: DetectedService
    let signIn: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                ProductLogo(service: service.service, tint: .primary)
                    .frame(width: 14, height: 14)
                Text(service.service.displayName)
                    .font(.caption.weight(.semibold))
                Spacer(minLength: 4)
            }

            if service.logins.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: service.isInstalled ? "person.crop.circle.badge.questionmark" : "questionmark.circle")
                        .font(.caption)
                    Text(service.isInstalled ? "Installed, but not signed in" : "Not installed on this Mac")
                        .font(.caption)
                    Spacer(minLength: 4)
                    // Being told the CLI is there but unused is only useful next to the way
                    // to fix it.
                    if service.isInstalled {
                        Button("Sign in", action: signIn)
                            .controlSize(.small)
                            .tint(service.service.accent)
                    }
                }
                .foregroundStyle(.secondary)
                .padding(.leading, 21)
            } else {
                ForEach(service.logins) { login in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(Palette.calm)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(login.email ?? "Signed in")
                                .font(.caption)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(login.configPath.map { abbreviate($0) } ?? "Default location")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .truncationMode(.head)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.leading, 21)
                }
            }
        }
    }

    private func abbreviate(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}
