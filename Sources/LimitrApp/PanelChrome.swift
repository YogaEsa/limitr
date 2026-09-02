import AppKit
import SwiftUI
import LimitrCore

/// When the panel will next ask the provider, so a number that has not moved reads as
/// "nothing has changed" rather than "this app has stopped working".
struct RefreshRow: View {
    let nextRefresh: Date?
    let service: AccountService
    let now: Date

    private var help: String {
        service == .claude
            ? "Claude usage is polled about every 3 minutes, and backs off further if Anthropic asks it to."
            : "Codex usage is polled every minute, and immediately whenever a session log changes."
    }

    var body: some View {
        HStack(spacing: 6) {
            if let nextRefresh, nextRefresh > now {
                Text("Next refresh in \(Format.seconds(to: nextRefresh, from: now))")
                    .monospacedDigit()
            } else {
                Text("Refreshing…")
            }
            Spacer(minLength: 4)
            Image(systemName: "info.circle").foregroundStyle(.tertiary)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Palette.railFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .help(help)
    }
}

/// The YOLO warning, asked in place.
///
/// Inline rather than a confirmation dialog: the menu-bar panel closes as soon as it stops
/// being the key window, so a sheet raised from it is liable to take the panel — and the
/// question — with it. Asking here keeps the question and its answer in the same window.
struct YoloConfirmBar: View {
    let service: AccountService
    let cancel: () -> Void
    let confirm: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "bolt.trianglebadge.exclamationmark.fill")
                .font(.system(size: 13))
                .foregroundStyle(Palette.watch)
            VStack(alignment: .leading, spacing: 1) {
                Text("Open \(service.tabName) in YOLO mode?")
                    .font(.caption.weight(.semibold))
                Text(service == .claude ? "No permission checks at all." : "No approval prompts, no sandbox.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button("Cancel", action: cancel)
                .controlSize(.small)
            Button("Open", action: confirm)
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
                .tint(Palette.watch)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(Palette.watch.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Palette.watch.opacity(0.32), lineWidth: 1)
        }
    }
}

/// The panel's confirmation for handing a service to another account.
///
/// A bar rather than a `confirmationDialog`, for the same reason `YoloConfirmBar` is one:
/// the panel is an `NSPanel` that SwiftUI closes as soon as it stops being key, so a modal
/// taking key would dismiss the surface it was asked about. The Accounts window is an
/// ordinary window and keeps the dialog.
struct ActivationConfirmBar: View {
    let prompt: ActivationPrompt
    let accent: Color
    let cancel: () -> Void
    let confirm: () -> Void

    var body: some View {
        // Buttons below the message rather than beside it. Sharing the row left the text
        // about half the panel's width, and this message is long enough that the bar then
        // grew to nine lines and filled the panel — which reads as an error rather than a
        // question. Stacked, the same words take two or three.
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Image(systemName: "largecircle.fill.circle")
                    .font(.system(size: 13))
                    .foregroundStyle(accent)
                Text(prompt.title)
                    .font(.caption.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            Text(prompt.message)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button("Cancel", action: cancel)
                    .controlSize(.small)
                Button(prompt.confirmTitle, action: confirm)
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                    .tint(accent)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(accent.opacity(0.32), lineWidth: 1)
        }
    }
}

/// The panel's "make this the default account" control.
///
/// Only offered for an account that already has a login. Choosing one by hand is what
/// switches `ActiveAccountChoice` to explicit, and from then on Limitr stops handing the
/// service to whichever account signs in first — too large a consequence to reach by
/// starring a signed-out account from a monitoring surface. The Accounts window keeps the
/// unrestricted version, where picking an account and then signing into it is a real flow.
struct DefaultAccountControl {
    let accountName: String
    let isDefault: Bool
    let isConnected: Bool
    let accent: Color
    let setDefault: () -> Void

    var help: String {
        if isDefault { return "\(accountName) is the default account" }
        if !isConnected { return "Sign in to \(accountName) before making it the default" }
        return "Make \(accountName) the default account"
    }
}

/// Identity on the left, controls on the right.
struct BottomBar: View {
    let profile: AccountProfile?
    let service: AccountService
    let isConnected: Bool
    /// nil where there is nothing to swap between, so the row never carries a control
    /// that can only ever be dead.
    let defaultAccount: DefaultAccountControl?
    let summary: String
    let refreshRotation: Double
    let refresh: () -> Void
    let openTerminal: () -> Void
    let openYolo: () -> Void
    let openAccounts: () -> Void

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(isConnected ? Palette.calm : Color.secondary.opacity(0.5))
                .frame(width: 6, height: 6)
            Text(profile?.name ?? "No account")
                .font(.caption.weight(.semibold))
                .lineLimit(1)
            Text(service.shortName)
                .font(.caption)
                .foregroundStyle(.tertiary)
            Spacer(minLength: 4)
            BarButton(systemImage: "arrow.clockwise", help: "Refresh now", rotation: refreshRotation, action: refresh)
                .keyboardShortcut("r")
            BarButton(systemImage: "terminal", help: "Open a terminal for this account", action: openTerminal)
                .disabled(profile == nil)
            BarButton(systemImage: "bolt.fill", help: "Open in YOLO mode", tint: Palette.watch, action: openYolo)
                .disabled(profile == nil)
            if let defaultAccount {
                BarButton(
                    systemImage: defaultAccount.isDefault ? "star.fill" : "star",
                    help: defaultAccount.help,
                    tint: defaultAccount.isDefault ? defaultAccount.accent : nil,
                    action: defaultAccount.setDefault
                )
                .disabled(defaultAccount.isDefault || !defaultAccount.isConnected)
            }
            BarButton(systemImage: "gearshape", help: "Accounts", action: openAccounts)
                .keyboardShortcut(",")
            BarButton(systemImage: "power", help: "Quit Limitr") { NSApplication.shared.terminate(nil) }
        }
        .help(summary)
    }
}

struct BarButton: View {
    let systemImage: String
    let help: String
    var rotation: Double = 0
    /// Set where the action carries a warning the icon alone would not convey.
    var tint: Color?
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11.5, weight: .medium))
                .rotationEffect(.degrees(rotation))
                .frame(width: 25, height: 22)
                .background(
                    isHovering ? Palette.railFill : Color.clear,
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                )
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(tint ?? (isHovering ? Color.primary : Color.secondary))
        .opacity(tint == nil || isHovering ? 1 : 0.75)
        .onHover { isHovering = $0 }
        .help(help)
        // A plain button wrapping a bare `Image` exposes no name to VoiceOver, and the
        // tooltip is not one — it is only reachable with a mouse already on the control.
        .accessibilityLabel(help)
    }
}
