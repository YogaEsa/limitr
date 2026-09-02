import AppKit
import Darwin
import SwiftUI
import Observation
import UserNotifications
import LimitrCore

@main
struct LimitrMenuApp: App {
    @State private var monitor: UsageMonitor
    @State private var notch: NotchController

    init() {
        // Must precede UsageMonitor, which loads the stored profiles on init.
        LegacyNameMigration.run()
        let monitor = UsageMonitor()
        monitor.start()
        let notch = NotchController(monitor: monitor)
        monitor.notch = notch
        notch.start()
        _monitor = State(initialValue: monitor)
        _notch = State(initialValue: notch)
    }

    var body: some Scene {
        // Withdrawn from the bar entirely in notch mode, rather than reduced to a bare
        // glyph. The notch already carries the readings and, since it opens the same
        // panel, the status item would be a second door onto one room.
        MenuBarExtra(isInserted: Binding(
            get: { monitor.surfaceMode == .menuBar },
            set: { _ in }
        )) {
            UsageMenu(monitor: monitor)
        } label: {
            MenuBarLabel(summary: monitor.menuBarSummary, threshold: monitor.preferences.redThreshold)
        }
        .menuBarExtraStyle(.window)
    }
}

/// The Settings window, owned in AppKit rather than declared as a SwiftUI `Settings` scene.
///
/// The scene's own opener cannot be reached from the notch. `@Environment(\.openSettings)`
/// is populated by a *scene*, and the notch's panel is a hand-built `NSHostingView` inside
/// an `NSPanel`, so the action never arrives. The usual stand-in — sending the
/// `showSettingsWindow:` selector — is worse than useless here: measured in this app it
/// reports the action *handled* and then creates nothing, so the button was silently dead
/// with no error to notice. Owning the window is what makes one call work from both
/// surfaces, and it costs nothing else: an `LSUIElement` app has no Settings menu item for
/// the scene to hang off anyway, and the gear button already carries the ⌘, shortcut.
@MainActor
enum SettingsScene {
    /// Held for the process's life. The window keeps its tab selection and scroll position
    /// between openings, and `isReleasedWhenClosed` is off so closing it is not a
    /// use-after-free the next time the gear is pressed.
    private static var window: NSWindow?

    static func open(monitor: UsageMonitor) {
        // Also what orders the monitoring panels out and lifts this above them — see
        // `WindowFronter`. On the first open the view does it as it enters the window.
        if WindowFrontingView.bringToFront() { return }

        let window = window ?? make(monitor: monitor)
        Self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private static func make(monitor: UsageMonitor) -> NSWindow {
        let window = NSWindow(
            contentRect: .zero,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Limitr"
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: SettingsWindow(monitor: monitor))
        window.contentView = host
        window.setContentSize(host.fittingSize)
        window.center()
        return window
    }
}


/// What the bar says without being clicked.
///
/// The whole reason a monitor sits in the menu bar is the glance that costs nothing, so
/// the live numbers belong here and not only behind the panel. While nothing is reporting
/// it falls back to the gauge alone — a bar reading "0%" would be claiming a measurement
/// it does not have.
///
/// The readings are laid out inside an `ImageRenderer` and handed to the bar as a single
/// `Image`, which is the point: a `MenuBarExtra` label does not lay out multi-view content
/// reliably. Measured by the status item's own width, a single `Text` sized to 118pt and a
/// static two-child `HStack` to 73pt, but a `ForEach` over two readings sized to 51pt and a
/// pair of `if let` slots to 65pt — one reading's width, with the second silently dropped
/// and nothing to show for it. Rendering offscreen puts the layout somewhere the ordinary
/// rules apply and gives the bar the one shape it handles.
private struct MenuBarLabel: View {
    let summary: MenuBarSummary
    let threshold: Int

    var body: some View {
        if let rendered {
            Image(nsImage: rendered)
                .renderingMode(.template)
                .accessibilityLabel(summary.items.map {
                    "\($0.source.displayName) \(Format.percent($0.percent))\($0.isLive ? "" : ", not live")"
                }.joined(separator: ", "))
        } else {
            Image(systemName: "gauge.with.dots.needle.67percent")
        }
    }

    /// A *template* image, which is what makes one rendering correct in both appearances.
    ///
    /// macOS draws a template menu-bar image from its alpha alone, white against a dark
    /// bar and black against a light one, and it tracks the bar rather than the app — which
    /// matters, because the menu bar's appearance does not always follow the system's.
    /// Baking a literal white would have been invisible in the light one, and any explicit
    /// colour, dynamic or not, is resolved once here and never re-resolved for the
    /// appearance the image ends up drawn against.
    private var rendered: NSImage? {
        guard !summary.isEmpty else { return nil }
        let renderer = ImageRenderer(content: MenuBarReadings(summary: summary, threshold: threshold))
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        guard let image = renderer.nsImage else { return nil }
        image.isTemplate = true
        return image
    }
}

/// One reading per service: its own mark, then how full its fullest window is.
///
/// The mark rather than the service's name, because the two products are recognised by
/// them and a bar has no room to spell things out. `ProductLogo` is the same glyph the
/// panel's tabs use, so the bar and the panel name the services the same way.
///
/// Drawn in flat black at varying opacity because the result is a template: only the alpha
/// survives, so opacity is the one channel left to say anything with. That is what carries
/// staleness here — the usage ramp's colours cannot, and a stale number presented exactly
/// like a live one is the claim `Staleness` exists to prevent.
private struct MenuBarReadings: View {
    let summary: MenuBarSummary
    let threshold: Int

    var body: some View {
        HStack(spacing: 8) {
            ForEach(summary.items) { item in
                HStack(spacing: 3.5) {
                    ProductLogo(service: item.source.service, tint: .black)
                        .frame(width: 11, height: 11)
                    Text(Format.percent(item.percent))
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Color.black)
                }
                .opacity(item.isLive ? 1 : 0.45)
            }
        }
        .padding(.horizontal, 1)
        .padding(.vertical, 2)
    }
}

/// The Settings scene: the accounts, and the handful of things worth letting someone
/// change.
///
/// Tabs rather than one long column. The two halves have nothing to do with each other,
/// and the panel is already crowded enough that adding a settings block to the accounts
/// list would make the busiest window busier.
struct SettingsWindow: View {
    @Bindable var monitor: UsageMonitor

    var body: some View {
        TabView {
            AccountsWindow(monitor: monitor)
                .tabItem { Label("Accounts", systemImage: "person.2") }
            GeneralSettings(monitor: monitor)
                .tabItem { Label("General", systemImage: "gearshape") }
        }
        // Held here rather than inside the accounts tab so the panel can still be ordered
        // behind this window while the other tab is showing.
        .background(WindowFronter())
    }
}

/// Where the reading goes, alerts, and whether Limitr starts with the Mac.
///
/// What is deliberately absent is the polling cadence. The 180-second Claude floor and its
/// 429 backoff are correctness constraints rather than taste — a control for them would
/// only offer someone a way to rate-limit themselves out of the data the app exists to
/// show.
private struct GeneralSettings: View {
    @Bindable var monitor: UsageMonitor

    private var threshold: Binding<Double> {
        Binding(
            get: { Double(monitor.preferences.redThreshold) },
            set: { monitor.preferences = monitor.preferences.with(redThreshold: Int($0.rounded())) }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 9) {
                Text("Show usage in").font(.body.weight(.medium))
                Picker("", selection: Binding(
                    get: { monitor.surfaceMode },
                    set: { monitor.surfaceMode = $0 }
                )) {
                    Text("The menu bar").tag(SurfaceMode.menuBar)
                    Text("The notch").tag(SurfaceMode.notch)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(monitor.surfaceMode == .notch
                     ? "The percentages sit beside the notch and the panel opens under it. Limitr leaves the menu bar entirely."
                     : "The percentages sit in the menu bar and the panel opens from them. Nothing is drawn near the notch.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider().opacity(0.5)

            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Text("Red line").font(.body.weight(.medium))
                    Spacer()
                    Text("\(monitor.preferences.redThreshold)%")
                        .font(.body.monospacedDigit())
                        .foregroundStyle(Palette.critical)
                }
                Slider(
                    value: threshold,
                    in: Double(NotificationPreferences.thresholdRange.lowerBound)...Double(NotificationPreferences.thresholdRange.upperBound),
                    step: 5
                )
                Text("The panel's bars turn red at this number too, so an alert and the panel can never disagree about what counts as trouble.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider().opacity(0.5)

            VStack(alignment: .leading, spacing: 7) {
                Toggle("Notify when a limit reaches the red line", isOn: Binding(
                    get: { monitor.preferences.alertsOnRed },
                    set: { monitor.preferences = monitor.preferences.with(alertsOnRed: $0) }
                ))
                Toggle("Notify when a limit resets", isOn: Binding(
                    get: { monitor.preferences.alertsOnReset },
                    set: { monitor.preferences = monitor.preferences.with(alertsOnReset: $0) }
                ))
                Text("At most one of each per window per cycle. The reset notice is the one that says you can start something heavy again.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider().opacity(0.5)

            LoginItemToggle()

            Spacer(minLength: 0)
        }
        .toggleStyle(.checkbox)
        .padding(18)
        .frame(width: 440, height: 430, alignment: .topLeading)
    }
}

/// Whether Limitr starts with the Mac.
///
/// Here rather than on the monitoring panel because it is a preference set once, and the
/// panel is for reading. It disappears entirely when there is no bundle to register —
/// `swift run LimitrApp` cannot become a login item, and a toggle that silently refuses
/// to move is worse than one that was never offered.
private struct LoginItemToggle: View {
    private let item = LoginItem()
    @State private var state: LoginItem.State = .disabled
    @State private var message: String?

    var body: some View {
        Group {
            if state != .unavailable {
                VStack(alignment: .leading, spacing: 1) {
                    Toggle("Open at login", isOn: Binding(get: { state == .enabled }, set: { apply($0) }))
                        .toggleStyle(.checkbox)
                        .font(.callout)
                    if state == .requiresApproval {
                        // Only the user can lift their own refusal, so the app points at
                        // where they do it rather than retrying a call that cannot work.
                        Button("Switched off in System Settings") { LoginItem.openSystemSettings() }
                            .buttonStyle(.link)
                            .font(.caption)
                    } else if let message {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(Palette.watch)
                    }
                }
            }
        }
        .onAppear { state = item.state }
    }

    private func apply(_ enabled: Bool) {
        do {
            try item.setEnabled(enabled)
            message = nil
        } catch {
            message = error.localizedDescription
        }
        state = item.state
    }
}

/// The menu-bar panel.
///
/// Reads top to bottom as one question narrowing: which service, which account of it, how
/// full each of that account's windows is, and what it spent getting there. The service
/// switch leads because it changes everything below it; the app's own identity and its
/// controls sit in the bottom bar, where they are reachable without being read first.
/// Whether clicking the active-account control on `profile` is a switch that needs
/// confirming, and what to say if so.
///
/// Shared by the panel's star and the Accounts window's radio because they are the only two
/// controls that can hand a service to another account, and a confirmation that describes
/// the consequence differently depending on which one you clicked is worse than none.
private func activationPrompt(for profile: AccountProfile) -> ActivationPrompt? {
    ActivationPrompt.forActivating(
        accountName: profile.name,
        serviceLabel: profile.service.displayName,
        isAlreadyActive: profile.isActive == true
    )
}

struct UsageMenu: View {
    @Bindable var monitor: UsageMonitor
    @State private var refreshRotation = 0.0
    @State private var selectedService: AccountService = .claude
    @State private var selectedAccountIDs: [AccountService: UUID] = [:]
    @State private var isConfirmingYolo = false
    /// The account the user asked to make active, held until they confirm. Switching is not
    /// a preference — it repoints every new terminal — so it is not something a single
    /// mis-aimed click on a monitoring surface should be able to do.
    @State private var pendingActivation: AccountProfile?
    @State private var installsShellIntegration = true

    /// Claude first: it is the service with the most windows to show, so it makes the
    /// better landing tab.
    private static let services: [AccountService] = [.claude, .codex]

    private var profiles: [AccountProfile] {
        monitor.profiles.filter { $0.service == selectedService && $0.isArchived != true }
    }

    /// The account whose usage is on screen: the one explicitly picked, else the active
    /// account if it is reporting, else whichever account has data to show.
    private var selectedProfile: AccountProfile? {
        if let id = selectedAccountIDs[selectedService],
           let profile = profiles.first(where: { $0.id == id }) { return profile }
        let reporting = profiles.filter { profile in
            monitor.windows.contains { $0.accountID == profile.id.uuidString }
        }
        return reporting.first(where: { $0.isActive == true })
            ?? reporting.first
            ?? profiles.first(where: { $0.isActive == true })
            ?? profiles.first
    }

    var body: some View {
        // Every relative time on the panel — countdowns, reset clocks, "3m ago" — is
        // rendered against this one instant so they can never disagree with each other.
        TimelineView(.periodic(from: .now, by: 1)) { context in
            panel(now: context.date)
        }
        .frame(width: 358)
    }

    private func panel(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            ServiceTabs(services: Self.services, selection: $selectedService)

            if profiles.count > 1 {
                AccountTabs(
                    profiles: profiles,
                    selectedID: selectedProfile?.id,
                    accent: selectedService.accent,
                    isConnected: monitor.isConnected,
                    isActive: { $0.isActive == true },
                    peakPercent: { profile in
                        monitor.windows
                            .filter { $0.accountID == profile.id.uuidString }
                            .map(\.usedPercent).max()
                    },
                    select: { selectedAccountIDs[selectedService] = $0.id }
                )
            }

            if let message = monitor.errorMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(Palette.watch)
                    .lineLimit(2)
            }

            ScrollView {
                VStack(spacing: 8) { cards(now: now) }
                    .padding(.bottom, 1)
            }
            .scrollIndicators(.never)
            .frame(height: 372)

            if isConfirmingYolo, let profile = selectedProfile {
                YoloConfirmBar(service: selectedService) {
                    withAnimation(.snappy(duration: 0.2)) { isConfirmingYolo = false }
                } confirm: {
                    isConfirmingYolo = false
                    monitor.openYolo(profile)
                }
                .transition(.opacity)
            } else if let profile = pendingActivation, let prompt = activationPrompt(for: profile) {
                ActivationConfirmBar(prompt: prompt, accent: profile.service.accent) {
                    withAnimation(.snappy(duration: 0.2)) { pendingActivation = nil }
                } confirm: {
                    pendingActivation = nil
                    withAnimation(.snappy(duration: 0.22)) { monitor.setActive(profile) }
                }
                .transition(.opacity)
            } else if !monitor.needsOnboarding {
                // Nothing is being polled yet, so a countdown would be describing a loop
                // that has not started.
                RefreshRow(
                    nextRefresh: monitor.nextRefresh(service: selectedService, profileID: selectedProfile?.id),
                    service: selectedService,
                    now: now
                )
            }

            BottomBar(
                profile: selectedProfile,
                service: selectedService,
                isConnected: selectedProfile.map(monitor.isConnected) ?? false,
                defaultAccount: defaultAccountControl,
                summary: monitor.summary,
                refreshRotation: refreshRotation,
                refresh: {
                    withAnimation(.snappy) { refreshRotation += 360 }
                    monitor.refresh()
                },
                openTerminal: { selectedProfile.map(monitor.open) },
                openYolo: { withAnimation(.snappy(duration: 0.2)) { isConfirmingYolo = true } },
                // `WindowFronter` closes this panel and orders the Accounts window above it.
                openAccounts: openAccounts
            )
        }
        .padding(12)
        // An armed warning belongs to the account it was armed for, not to whatever the
        // user switched to afterwards.
        .onChange(of: selectedService) { isConfirmingYolo = false; pendingActivation = nil }
        .onChange(of: selectedProfile?.id) { isConfirmingYolo = false; pendingActivation = nil }
    }

    private var skipOnboarding: (() -> Void)? {
        guard monitor.canSkipOnboarding else { return nil }
        return { monitor.finishOnboarding() }
    }

    /// Shown for a single account too, unlike `AccountTabs`, which really does have
    /// nothing to swap between. The star was gated on more than one account on the
    /// grounds that it would otherwise sit there permanently lit and inert — but lit is
    /// the whole point: it is the only place the panel says which account new terminals
    /// inherit, and hiding it reads as the service having no default at all.
    private var defaultAccountControl: DefaultAccountControl? {
        guard let profile = selectedProfile else { return nil }
        return DefaultAccountControl(
            accountName: profile.name,
            isDefault: profile.isActive == true,
            isConnected: monitor.isConnected(profile),
            accent: selectedService.accent,
            setDefault: {
                // Clicking the account that already holds the service is how the user pins
                // it rather than a switch, so it goes straight through — see `setActive`.
                if activationPrompt(for: profile) == nil { monitor.setActive(profile) }
                else { withAnimation(.snappy(duration: 0.2)) { pendingActivation = profile } }
            }
        )
    }

    @ViewBuilder
    private func cards(now: Date) -> some View {
        if monitor.needsOnboarding {
            DetectionCard(
                state: monitor.detection,
                canInstallShellIntegration: monitor.canInstallShellIntegration,
                installsShellIntegration: $installsShellIntegration,
                detect: monitor.detectInstallations,
                adopt: { monitor.adoptDetectedInstallations(installingShellIntegration: installsShellIntegration) },
                signIn: monitor.connectDefault,
                skip: skipOnboarding
            )
        } else if let profile = selectedProfile {
            let windows = monitor.windows
                .filter { $0.accountID == profile.id.uuidString }
                // Shortest window first: the 5-hour session is the one that decides whether
                // you can keep working right now.
                .sorted { ($0.windowMinutes, $0.label) < ($1.windowMinutes, $1.label) }

            if windows.isEmpty {
                if monitor.isConnected(profile) {
                    AwaitingUsageCard(profile: profile, email: monitor.email(for: profile)) { monitor.open(profile) }
                } else {
                    DisconnectedCard(service: selectedService) { monitor.connect(profile) }
                }
            } else {
                ForEach(windows) { window in
                    UsageCard(
                        window: window,
                        now: now,
                        trend: monitor.trend(for: window),
                        burnRate: monitor.burnRate(for: window, now: now),
                        accountError: monitor.accountError(for: window),
                        threshold: monitor.preferences.redThreshold
                    )
                }
            }

            if let extra = monitor.extraUsage[profile.id], extra.utilization != nil {
                ExtraUsageCard(extraUsage: extra, threshold: monitor.preferences.redThreshold)
            }

            if let report = monitor.tokenReports[profile.id] {
                TokenUsageCard(report: report, service: selectedService, now: now)
            }
        } else {
            DisconnectedCard(service: selectedService, connect: openAccounts)
        }
    }

    private func openAccounts() {
        SettingsScene.open(monitor: monitor)
    }
}

/// One service's accounts, headed by its mark.
///
/// No longer collapsible: with the card styling the two panels now share, a section that
/// hides its contents by default meant opening Accounts and being shown nothing. Three
/// accounts per service is a bounded list, so it can simply be on screen.
private struct ServiceSection<Content: View>: View {
    let service: AccountService
    let accountCount: Int
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                ProductLogo(service: service, tint: .primary)
                    .frame(width: 15, height: 15)
                Text(service.displayName)
                    .font(.subheadline.weight(.semibold))
                Text("\(accountCount)/\(AccountProfile.maximumPerService)")
                    .font(.caption2.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(Palette.railFill, in: Capsule())
                Spacer()
            }
            content
        }
    }
}

/// One account: which one new terminals use, who it is signed in as, and what can be done
/// with it. The controls are the same glyphs as the monitoring panel's bottom bar, so the
/// two windows do not teach two vocabularies for one action.
private struct AccountRow: View {
    @Bindable var monitor: UsageMonitor
    let profile: AccountProfile
    let canRemove: Bool
    @Binding var yoloProfile: AccountProfile?
    /// Held by the window rather than the row so the confirmation is one dialog the window
    /// presents, the way the YOLO one already is — a row that owned its own could put two
    /// on screen at once.
    @Binding var activatingProfile: AccountProfile?

    var body: some View {
        let connected = monitor.isConnected(profile)
        let isActive = profile.isActive == true
        let settling = monitor.isSettling(profile)

        HStack(spacing: 9) {
            Button {
                // Straight through when it is not a switch — clicking the account that
                // already holds the service is how the user pins it. See `setActive`.
                if activationPrompt(for: profile) == nil {
                    withAnimation(.snappy(duration: 0.22)) { monitor.setActive(profile) }
                } else {
                    activatingProfile = profile
                }
            } label: {
                Image(systemName: isActive ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 13))
                    .foregroundStyle(isActive ? profile.service.accent : Color.secondary)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help(isActive ? "New terminals use this account" : "Make this the account new terminals use")

            VStack(alignment: .leading, spacing: 1) {
                TextField("Account name", text: monitor.nameBinding(for: profile.id))
                    .textFieldStyle(.plain)
                    .font(.body.weight(.medium))
                if settling {
                    Text(connected ? "Signing out in Terminal…" : "Waiting for the browser sign-in…")
                        .font(.caption2).foregroundStyle(.secondary)
                } else if let message = monitor.accountErrors[profile.id] {
                    Text(message).font(.caption2).foregroundStyle(Palette.watch).lineLimit(2)
                } else if let email = monitor.email(for: profile) {
                    Text(email).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                } else {
                    Text(connected ? "Signed in" : "Not signed in")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 6)

            if connected {
                Circle().fill(Palette.calm).frame(width: 6, height: 6)
                BarButton(systemImage: "terminal", help: "Open a terminal for this account") { monitor.open(profile) }
                BarButton(systemImage: "bolt.fill", help: "Open in YOLO mode", tint: Palette.watch) { yoloProfile = profile }
                Menu {
                    Button("Sign out") { monitor.disconnect(profile) }
                    if canRemove {
                        Button("Remove account", role: .destructive) { monitor.remove(profile) }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 20)
                .help("More actions")
            } else if settling {
                ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 20)
            } else {
                Button("Sign in") { monitor.connect(profile) }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                    .tint(profile.service.accent)
                if canRemove {
                    BarButton(systemImage: "trash", help: "Remove this account") { monitor.remove(profile) }
                }
            }
        }
        .padding(9)
        .background(Palette.cardFill, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(
                    isActive ? profile.service.accent.opacity(0.45) : Palette.cardStroke,
                    lineWidth: isActive ? 1 : 0.75
                )
        }
    }
}

struct AccountsWindow: View {
    @Bindable var monitor: UsageMonitor
    @Environment(\.dismiss) private var dismiss
    @State private var yoloProfile: AccountProfile?
    @State private var activatingProfile: AccountProfile?

    /// Claude first, matching the panel's tab order.
    private static let services: [AccountService] = [.claude, .codex]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Accounts").font(.title3.weight(.semibold))
                    Text("Up to \(AccountProfile.maximumPerService) per service. The selected account is the one new terminals use.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }

            if let message = monitor.errorMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(Palette.watch)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Palette.watch.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            }

            ForEach(Self.services, id: \.self) { service in
                let profiles = monitor.profiles.filter { $0.service == service && $0.isArchived != true }
                ServiceSection(service: service, accountCount: profiles.count) {
                    ForEach(profiles) { profile in
                        AccountRow(
                            monitor: monitor,
                            profile: profile,
                            canRemove: profiles.count > 1,
                            yoloProfile: $yoloProfile,
                            activatingProfile: $activatingProfile
                        )
                    }
                }
            }

            Divider().opacity(0.5)

            HStack(spacing: 8) {
                Menu {
                    Button(monitor.hasArchivedAccount(for: .claude) ? "Rebind Claude Code account" : "Claude Code account") { monitor.addClaudeAccount() }
                        .disabled(!monitor.canAddAccount(for: .claude))
                    Button(monitor.hasArchivedAccount(for: .codex) ? "Rebind ChatGPT Codex account" : "ChatGPT Codex account") { monitor.addCodexAccount() }
                        .disabled(!monitor.canAddAccount(for: .codex))
                } label: {
                    Label("Add account", systemImage: "plus")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(!AccountService.allCases.contains(where: monitor.canAddAccount))
                Spacer()
            }
        }
        .padding(18)
        .frame(width: 440)
        .onAppear { monitor.isAccountsWindowVisible = true }
        .onDisappear { monitor.isAccountsWindowVisible = false }
        .confirmationDialog(
            "Open \(yoloProfile?.name ?? "this account") in YOLO mode?",
            isPresented: Binding(get: { yoloProfile != nil }, set: { if !$0 { yoloProfile = nil } })
        ) {
            Button("Open YOLO mode", role: .destructive) {
                if let profile = yoloProfile { monitor.openYolo(profile) }
                yoloProfile = nil
            }
            Button("Cancel", role: .cancel) { yoloProfile = nil }
        } message: {
            Text(yoloProfile?.service == .claude
                 ? "Claude Code will run without any permission checks. Only use this in a trusted directory."
                 : "ChatGPT Codex will run without approval prompts or sandbox protection. Only use this in a trusted directory.")
        }
        .confirmationDialog(
            activatingProfile.flatMap(activationPrompt(for:))?.title ?? "",
            isPresented: Binding(
                get: { activatingProfile != nil },
                set: { if !$0 { activatingProfile = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(ActivationPrompt.confirmTitle) {
                if let profile = activatingProfile {
                    withAnimation(.snappy(duration: 0.22)) { monitor.setActive(profile) }
                }
                activatingProfile = nil
            }
            Button("Cancel", role: .cancel) { activatingProfile = nil }
        } message: {
            if let prompt = activatingProfile.flatMap(activationPrompt(for:)) { Text(prompt.message) }
        }
    }
}

@MainActor
@Observable
final class UsageMonitor {
    var windows: [UsageWindow] = [] { didSet { recordHistory() } }
    var errorMessage: String?
    var profiles: [AccountProfile]
    /// Set at launch, before anything has a chance to persist. A first run is the whole
    /// reason the welcome screen exists, and "no profiles were ever saved" is the only
    /// honest way to recognise one.
    private var isOnboarding: Bool
    /// Token spend per account, aggregated from that account's own transcripts.
    var tokenReports: [UUID: TokenUsageReport] = [:]
    /// Extra-usage credit spend per Claude account, for the accounts that have it on.
    var extraUsage: [UUID: ExtraUsage] = [:]
    private var ledgers: [UUID: TokenUsageLedger] = [:]
    private var ledgerScans: Set<UUID> = []
    /// Recent readings per window, so a card can say which way it is moving and when it
    /// would be full. Loaded from disk at launch, which is what puts a trend and a
    /// projection on screen immediately rather than ten minutes in.
    private var history = UsageHistoryStore.load(from: UsageMonitor.historyURL)
    private var nextCodexRefresh: Date?
    private var nextClaudeRefresh: [UUID: Date] = [:]
    var detection: DetectionState = .idle
    /// The welcome screen is only correct once connectivity is actually known. Without
    /// this it flashes on every launch, because no snapshot has landed yet.
    private var hasReadAccountsFromDisk = false
    private var notifier = Notifier()
    /// Set once at launch by `LimitrMenuApp`, so an alert can reach the notch as well as
    /// the notification centre.
    weak var notch: NotchController?
    /// What the user wants to be told about. Saved on every change, and a change rebuilds
    /// `rules`: the threshold is part of the dedupe key, so what has already been sent
    /// under the old one no longer describes the new question.
    var preferences: NotificationPreferences = .load() {
        didSet {
            guard preferences != oldValue else { return }
            preferences.save()
            rules = NotificationRules(preferences: preferences)
        }
    }
    /// Which surface carries the always-on reading. Saved on every change, and the notch
    /// layer is built or taken away to match: the two are exclusive, so switching to the
    /// menu bar has to actually dismantle the layer rather than hide it.
    var surfaceMode: SurfaceMode = .load() {
        didSet {
            guard surfaceMode != oldValue else { return }
            surfaceMode.save()
            notch?.apply(surfaceMode)
        }
    }
    private var rules = NotificationRules(preferences: .load())
    private var timer: Timer?
    private var watchers: [TranscriptWatcher] = []
    /// Which service is working right now. Ticked by the transcript watchers, decayed by
    /// `activityTicker`, and read by the notch.
    var activity = ActivityPulse()
    /// Runs only while something is active, so an idle Mac runs no timer for this at all.
    private var activityTicker: Timer?
    private var codexTask: Task<Void, Never>?
    var accountErrors: [UUID: String] = [:]
    private var claudeTasks: [UUID: Task<Void, Never>] = [:]
    /// Backoff for failures that spent a request. See `nextClaudeInterval`.
    private var claudeDelays: [UUID: TimeInterval] = [:]
    /// Consecutive failures that never reached the network. Counted separately from
    /// `claudeDelays` because they cost no rate-limit budget to retry.
    private var claudeLocalRetries: [UUID: Int] = [:]
    private var claudeStatuses: [UUID: ClaudeAccountStatus] = [:]
    /// One per account with a sign-in or sign-out in flight. See `watchConnectivity`.
    private var connectivityWatches: [UUID: Task<Void, Never>] = [:]
    /// Identifies the task allowed to clear each watch. A cancelled task can finish after a
    /// retry has started; without this token, the old task clears the new retry's state.
    private var connectivityWatchTokens: [UUID: UUID] = [:]
    private var started = false
    /// Cached on-disk identity per account. See `refreshAccountSnapshots`.
    private var accountSnapshots: [UUID: AccountSnapshot] = [:]
    private var snapshotTask: Task<Void, Never>?
    /// A login lands while the user is watching the Accounts window, so status is polled
    /// quickly there and left to idle the rest of the time.
    var isAccountsWindowVisible = false {
        didSet { if isAccountsWindowVisible != oldValue { refreshAccountSnapshots() } }
    }

    init() {
        let stored = AccountProfileStorage.loadStored()
        let known = stored ?? AccountProfile.defaults
        let recovered = AccountProfileStorage.adoptingOrphans(into: known)
        profiles = recovered
        // Recovering accounts is the answer to "the list came back empty", so it settles
        // the same question the welcome screen asks. Treating it as a first run anyway
        // would offer to set up accounts that are already sitting there signed in.
        isOnboarding = stored == nil && recovered.count == known.count
        if recovered.count != known.count { AccountProfileStorage.save(recovered) }
    }

    var summary: String {
        let parts = menuBarSummary.items.map { "\($0.source.service.tabName) \(Int($0.percent.rounded()))%" }
        return parts.isEmpty ? "Limitr" : parts.joined(separator: " · ")
    }

    /// The reading the menu bar itself shows. See `MenuBarSummary` for which window and
    /// which account speak for a service.
    var menuBarSummary: MenuBarSummary {
        MenuBarSummary.make(windows: windows, accountIDs: activeAccountIDs())
    }

    /// The same reading the menu bar shows, plus what the notch has room for: the reset
    /// countdown, the trend, the projection, and whether that service is working.
    var notchSummary: NotchSummary {
        NotchSummary.make(
            windows: windows,
            accountIDs: activeAccountIDs(),
            history: history,
            activity: activity,
            now: .now
        )
    }

    /// The account each service is standing on, keyed by service. Shared by the two
    /// summaries so they can never be looking at different accounts.
    private func activeAccountIDs() -> [UsageSource: String] {
        var accountIDs: [UsageSource: String] = [:]
        for source in UsageSource.allCases {
            if let primary = primaryProfile(for: source) { accountIDs[source] = primary.id.uuidString }
        }
        return accountIDs
    }

    /// The account a service speaks with: the one new terminals inherit, falling back to
    /// its only other candidate so a service with a single unstarred account still reports.
    private func primaryProfile(for source: UsageSource) -> AccountProfile? {
        let service = source.service
        return profiles.first { $0.service == service && $0.isArchived != true && $0.isActive == true }
            ?? profiles.first { $0.service == service && $0.isArchived != true }
    }

    func setActive(_ profile: AccountProfile) {
        // Marked before the early return, so that clicking the account already selected is
        // a way to say "stop reassigning this" — from here on the service's active account
        // is the user's business, not something to re-derive from who is signed in.
        ActiveAccountChoice.markExplicit(profile.service, account: profile.id)
        let anotherAccountIsConnected = profiles.contains {
            $0.id != profile.id && $0.service == profile.service
                && $0.isArchived != true && isConnected($0)
        }
        guard isConnected(profile) || isSettling(profile) || !anotherAccountIsConnected else {
            // Remember the choice, but do not publish a home with no credential over a
            // working account. `connect` makes the remembered choice active as soon as its
            // Terminal login starts.
            accountErrors[profile.id] = "Sign in first. This account will become the default when sign-in starts."
            if normalizeActiveProfiles() { publishActiveAccount() }
            return
        }
        accountErrors[profile.id] = nil
        for index in profiles.indices where profiles[index].service == profile.service && profiles[index].isArchived != true {
            profiles[index].isActive = profiles[index].id == profile.id
        }
        // Persist and publish in the click handler. `Done` only closes the window.
        saveProfiles()
        publishActiveAccount()
        // "Default" is a promise about terminal behavior. Taking that explicit action
        // finishes the shell integration even if onboarding was skipped, and also upgrades
        // a source-only install with live swaps.
        installActiveAccountShell()
    }

    /// Mirrors the active accounts into the file new shells source. Safe to call often;
    /// it only rewrites one Limitr-owned file and never touches the user's shell config.
    func publishActiveAccount() {
        func active(_ service: AccountService) -> AccountProfile? {
            profiles.first { $0.service == service && $0.isArchived != true && $0.isActive == true }
                ?? profiles.first { $0.service == service && $0.isArchived != true }
        }
        do {
            let codexHome = active(.codex)?.codexHomePath
            let defaultCodexHome = FileManager.default.homeDirectoryForCurrentUser
                .appending(path: ".codex").standardizedFileURL.path
            try ActiveAccountShell.write(
                codexHome: codexHome.flatMap {
                    URL(fileURLWithPath: $0).standardizedFileURL.path == defaultCodexHome ? nil : $0
                },
                claudeConfigPath: active(.claude)?.claudeConfigPath
            )
        } catch { errorMessage = error.localizedDescription }
    }

    /// Wires new terminals up to the active account, with no setting and no prompt.
    ///
    /// This used to be opt-in behind a confirmation dialog, which meant the common case —
    /// wanting the account you just picked to be the one your next shell uses — took an
    /// extra decision to reach. `install` appends a single line only if the profile does
    /// not already have it, and `ActiveAccountShell` never touches the profile again after
    /// that; everything else it does is confined to its own file.
    private func installActiveAccountShell() {
        do {
            try ActiveAccountShell.install()
            canInstallShellIntegration = !ActiveAccountShell.isInstalled()
        }
        catch { errorMessage = error.localizedDescription }
    }

    func accountCount(for source: UsageSource) -> Int {
        max(Set(windows.filter { $0.source == source }.map(\.accountID)).count, connectedProfiles(for: source).count)
    }

    func connectedProfiles(for source: UsageSource) -> [AccountProfile] {
        let service: AccountService = source == .codex ? .codex : .claude
        return profiles.filter { $0.service == service && $0.isArchived != true && isConnected($0) }
    }

    func isConnected(_ profile: AccountProfile) -> Bool {
        accountSnapshots[profile.id]?.isConnected ?? false
    }

    /// Whether a sign-in or sign-out for this account is still out in Terminal. The row
    /// says so rather than leaving a button that looks like it did nothing.
    func isSettling(_ profile: AccountProfile) -> Bool {
        connectivityWatches[profile.id] != nil
    }

    func email(for profile: AccountProfile) -> String? {
        accountSnapshots[profile.id]?.email
    }

    /// Re-reads every account's on-disk identity off the main thread.
    ///
    /// `isConnected` and `email` are called straight from `body` — once per profile per
    /// group, then again per usage card — and they used to hit the filesystem each time.
    /// For the default Claude profile that meant decoding `~/.claude.json`, which is 65 KB
    /// on an ordinary install, on every render pass and on every tick of the Accounts
    /// window's two-second poll. Reading it here and letting the views read a dictionary is
    /// what takes the stutter out of opening the panel.
    private func refreshAccountSnapshots() {
        guard snapshotTask == nil else { return }
        let inputs = profiles.filter { $0.isArchived != true }.map {
            SnapshotInput(
                id: $0.id,
                service: $0.service,
                codexAuth: $0.codexHomePath.map { URL(fileURLWithPath: $0).appending(path: "auth.json") },
                claudeConfig: $0.claudeConfigDirectory,
                claudeConfigPath: $0.claudeConfigPath
            )
        }
        // An authoritative "logged out" overrides the evidence on disk, which is what
        // catches an oauthAccount left behind by `claude auth logout`. Only a definite CLI
        // answer, never a probe that merely failed to run — see `ClaudeConnectivity`.
        let loggedOut = Set(claudeStatuses.filter { $0.value.isDefinitelyLoggedOut }.map(\.key))

        snapshotTask = Task.detached(priority: .utility) { [weak self] in
            var snapshots: [UUID: AccountSnapshot] = [:]
            for input in inputs {
                switch input.service {
                case .codex:
                    let metadata = input.codexAuth.flatMap { CodexAccountMetadata.read(from: $0) }
                    // The file existing is not the login: `auth.json` also holds an auth
                    // mode, an account id and a refresh stamp, so one left behind with its
                    // tokens cleared still exists. See `CodexConnectivity`.
                    let credential = input.codexAuth.map { CodexConnectivity.credential(authFile: $0) } ?? .absent
                    snapshots[input.id] = AccountSnapshot(
                        isConnected: CodexConnectivity.isSignedIn(credential: credential),
                        email: metadata?.email,
                        credential: credential
                    )
                case .claude:
                    let metadata = ClaudeAccountMetadata.read(configDirectory: input.claudeConfig)
                    // The config file is the cheap half of the answer and the only source
                    // of the email, so a directory without an account in it skips the
                    // Keychain lookup entirely rather than spawning `security` per tick.
                    let credential: CredentialPresence = metadata == nil
                        ? .absent
                        : ClaudeConnectivity.credential(configDirectory: input.claudeConfigPath)
                    snapshots[input.id] = AccountSnapshot(
                        isConnected: ClaudeConnectivity.isSignedIn(
                            configNamesAccount: metadata != nil,
                            credential: credential,
                            cliVerdict: loggedOut.contains(input.id) ? .loggedOut : .unknown
                        ),
                        email: metadata?.email,
                        credential: credential
                    )
                }
            }
            await self?.applyAccountSnapshots(snapshots)
        }
    }

    private func applyAccountSnapshots(_ snapshots: [UUID: AccountSnapshot]) {
        snapshotTask = nil
        // Deferred, so it is never true while `accountSnapshots` still holds the empty
        // dictionary it started with — that window would read as "nothing is signed in"
        // and put the welcome screen in front of a user who has accounts.
        defer { hasReadAccountsFromDisk = true }
        // A credential that has appeared or gone makes any cached CLI verdict stale: the
        // probe answered about a Keychain state that no longer holds. Dropping it here is
        // what lets a sign-in completed outside Limitr — or after a watch took its
        // reading too early — reach the row without a relaunch. A first reading clears
        // nothing, so the probe `start()` takes at launch survives it.
        for (id, snapshot) in snapshots {
            guard let previous = accountSnapshots[id] else { continue }
            if previous.credential != snapshot.credential { claudeStatuses[id] = nil }
            if previous.isConnected != snapshot.isConnected {
                // The snapshot is the UI's source of truth, so let the same transition
                // end the in-flight label immediately. Leaving that cleanup solely to
                // the polling task could strand a completed browser login on “Waiting”.
                connectivityWatches[id]?.cancel()
                connectivityWatches[id] = nil
                connectivityWatchTokens[id] = nil
            }
        }
        guard snapshots != accountSnapshots else { return }
        let connectivityChanged = snapshots.mapValues(\.isConnected) != accountSnapshots.mapValues(\.isConnected)
        // Computed before the reading is replaced, because it is a comparison against it.
        let arrived = ConnectivityTransition.newlyConnected(
            previous: accountSnapshots.mapValues(\.isConnected),
            current: snapshots.mapValues(\.isConnected)
        )
        accountSnapshots = snapshots
        // A sign-in that lands answers the welcome screen's question, and this is the only
        // place that hears about one: `connect` hands the login to Terminal and returns
        // immediately, so the result arrives minutes later and out of band. Without this
        // the latch stayed set — the card sat in front of a working account, and the user
        // had to run the scan a second time to dismiss a question they had already
        // answered. `saveProfiles` is the other half: `connect` persists nothing, so a
        // first run with nothing but the default profiles never wrote an account list, and
        // `loadStored` returning nil made every later launch a first run again.
        if isOnboarding, !arrived.isEmpty {
            finishOnboarding()
            saveProfiles()
        }
        if normalizeActiveProfiles() { publishActiveAccount() }
        guard connectivityChanged else { return }
        // A sign-in or sign-out finished in Terminal: pick up its windows and watchers.
        refreshCodex()
        restartClaudeLoops()
        resetWatchers()
    }

    private func startSnapshotLoop() {
        snapshotTask?.cancel()
        snapshotTask = nil
        Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.refreshAccountSnapshots()
                try? await Task.sleep(for: self.isAccountsWindowVisible ? .seconds(2) : .seconds(30))
            }
        }
    }

    /// Guarantees exactly one active profile per service.
    ///
    /// The active account is what the menu-bar title summarises and what new terminals
    /// inherit, so "none selected" is not a usable state — and, because it is what new
    /// terminals inherit, it cannot be an account with no login either. `ActiveAccountResolver`
    /// holds the rule: a choice the user made by hand wins while the account it names is
    /// signed in or still signing in, and is lent to a signed-in account otherwise.
    @discardableResult
    private func normalizeActiveProfiles() -> Bool {
        var changed = false
        for service in AccountService.allCases {
            let indices = profiles.indices.filter {
                profiles[$0].service == service && profiles[$0].isArchived != true
            }
            guard !indices.isEmpty else { continue }
            let byID = Dictionary(uniqueKeysWithValues: indices.map { (profiles[$0].id, $0) })
            let active = indices.first(where: { profiles[$0].isActive == true }).map { profiles[$0].id }
            let resolved = ActiveAccountResolver.resolve(
                candidates: indices.map { profiles[$0].id },
                connected: Set(indices.filter { isConnected(profiles[$0]) }.map { profiles[$0].id }),
                active: active,
                // A choice made before Limitr recorded *which* account was picked is read
                // off the account standing active at the time, so upgrading does not
                // quietly discard it.
                chosen: ActiveAccountChoice.chosen(service)
                    ?? (ActiveAccountChoice.isExplicit(service) ? active : nil),
                // A sign-in reads as disconnected for the whole of its run, so the account
                // waiting on Terminal keeps the default rather than losing it to a poll.
                settling: Set(indices.map { profiles[$0].id }.filter { connectivityWatches[$0] != nil })
            )
            guard let chosen = resolved.flatMap({ byID[$0] }) else { continue }
            for index in indices where (profiles[index].isActive == true) != (index == chosen) {
                profiles[index].isActive = index == chosen
                changed = true
            }
        }
        if changed { saveProfiles() }
        return changed
    }

    func email(for window: UsageWindow) -> String? {
        guard let profile = profiles.first(where: { $0.id.uuidString == window.accountID }) else { return nil }
        return email(for: profile)
    }

    func accountError(for window: UsageWindow) -> String? {
        guard let profile = profiles.first(where: { $0.id.uuidString == window.accountID }) else { return nil }
        return accountErrors[profile.id]
    }

    // MARK: - Trend and projection

    nonisolated static let historyURL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appending(path: "Limitr/usage-history.json")

    private func recordHistory(now: Date = .now) {
        history.record(windows, now: now)
        // Saving is a write per poll of a file bounded by the history's own 90-minute
        // memory, so it stays small — but it is still a write, and it does not belong on
        // the actor the panel is drawn from.
        let snapshot = history
        let url = Self.historyURL
        Task.detached(priority: .utility) {
            try? UsageHistoryStore.save(snapshot, to: url)
        }
    }

    /// Percentage points added over the last hour and a half, or nil before there is
    /// enough history to say.
    func trend(for window: UsageWindow, now: Date = .now) -> Double? {
        history.trend(for: window, now: now)
    }

    /// When this window would be full at the rate it has been filling, or nil when the
    /// honest answer is silence. See `BurnRate`.
    func burnRate(for window: UsageWindow, now: Date = .now) -> BurnRate? {
        history.burnRate(for: window, now: now)
    }

    // MARK: - Detecting existing installations

    /// The welcome screen belongs on a first run — the point of the feature — and again
    /// whenever nothing is signed in, which is the same question asked later.
    ///
    /// Gating it on "nothing connected" alone would have hidden it from almost everyone:
    /// the common first run is someone who is *already* logged into both CLIs at their
    /// default paths, which Limitr picks up on its own.
    var needsOnboarding: Bool {
        guard hasReadAccountsFromDisk else { return false }
        return isOnboarding || !hasConnectedAccount
    }

    private var hasConnectedAccount: Bool {
        profiles.contains { $0.isArchived != true && isConnected($0) }
    }

    /// Whether leaving the welcome screen would land somewhere useful.
    var canSkipOnboarding: Bool { hasConnectedAccount }

    func finishOnboarding() {
        isOnboarding = false
        detection = .idle
    }

    /// Cached, not computed: `body` runs once a second under the panel's `TimelineView`,
    /// and this answer comes from reading shell profiles off disk. It can only change when
    /// Limitr itself installs the line.
    private(set) var canInstallShellIntegration = !ActiveAccountShell.isInstalled()

    func detectInstallations() {
        guard detection != .scanning else { return }
        detection = .scanning
        Task { [weak self] in
            // Both halves touch the filesystem and one of them starts a login shell, so
            // neither belongs on the main actor.
            let services = await Task.detached(priority: .userInitiated) {
                let environment = LoginShellEnvironment.read(["CLAUDE_CONFIG_DIR", "CODEX_HOME"])
                return InstallationScanner(
                    home: FileManager.default.homeDirectoryForCurrentUser,
                    applicationSupport: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0],
                    environment: environment
                ).scan()
            }.value
            self?.detection = .done(services)
        }
    }

    /// Binds every login the scan found to a profile, reusing any profile that already
    /// points at the same place rather than making a second one for it.
    func adoptDetectedInstallations(installingShellIntegration: Bool) {
        guard let services = detection.results else { return }
        for service in services {
            for login in service.logins { adopt(login, for: service.service) }
        }
        normalizeActiveProfiles()
        saveProfiles()
        publishActiveAccount()
        if installingShellIntegration {
            installActiveAccountShell()
            canInstallShellIntegration = !ActiveAccountShell.isInstalled()
        }
        finishOnboarding()
        // Connectivity for a newly bound profile is unknown until it has been read.
        refreshAccountSnapshots()
        resetWatchers()
    }

    private func adopt(_ login: DetectedLogin, for service: AccountService) {
        let matches: (AccountProfile) -> Bool = { profile in
            guard profile.service == service else { return false }
            switch service {
            case .claude:
                return Self.samePath(profile.claudeConfigPath, login.configPath)
            case .codex:
                // A Codex profile always carries a home; nil from the scan means `~/.codex`.
                let expected = login.configPath ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".codex").path
                return Self.samePath(profile.codexHomePath, expected)
            }
        }

        if let index = profiles.firstIndex(where: matches) {
            // Re-binding an account the user removed earlier is exactly what archiving is
            // for: its isolated login and sessions are still on disk.
            profiles[index].isArchived = nil
            return
        }
        guard canAddAccount(for: service) else { return }

        let id = UUID()
        let name = login.email.map { String($0.prefix(while: { $0 != "@" })) }
            ?? "Account \(profiles.filter { $0.service == service && $0.isArchived != true }.count + 1)"
        switch service {
        case .claude:
            profiles.append(AccountProfile(id: id, service: .claude, name: name, claudeConfigPath: login.configPath))
        case .codex:
            let home = login.configPath ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".codex").path
            profiles.append(AccountProfile(id: id, service: .codex, name: name, codexHomePath: home))
        }
    }

    /// Signs in the profile a service already has, for the case where the CLI is installed
    /// but nobody has logged into it yet.
    func connectDefault(_ service: AccountService) {
        guard let profile = profiles.first(where: { $0.service == service && $0.isArchived != true }) else { return }
        connect(profile)
    }

    private static func samePath(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhs, let rhs else { return lhs == nil && rhs == nil }
        return URL(fileURLWithPath: lhs).standardizedFileURL.path == URL(fileURLWithPath: rhs).standardizedFileURL.path
    }

    // MARK: - Token ledgers

    /// When the panel expects the next automatic poll for this account.
    func nextRefresh(service: AccountService, profileID: UUID?) -> Date? {
        service == .codex ? nextCodexRefresh : profileID.flatMap { nextClaudeRefresh[$0] }
    }

    /// One ledger per account, kept for the app's lifetime: each holds the byte cursors
    /// that make every scan after the first one nearly free.
    private func ledger(for profile: AccountProfile) -> TokenUsageLedger? {
        if let existing = ledgers[profile.id] { return existing }
        guard let root = transcriptRoot(for: profile) else { return nil }
        let ledger = TokenUsageLedger(flavor: profile.service == .codex ? .codex : .claude, root: root)
        ledgers[profile.id] = ledger
        return ledger
    }

    private func refreshTokenUsage(for profile: AccountProfile) {
        guard let ledger = ledger(for: profile), ledgerScans.insert(profile.id).inserted else { return }
        let id = profile.id
        Task { [weak self] in
            // The scan runs on the ledger's own actor, never on the main one: the first
            // pass over a well-used install reads tens of megabytes.
            let report = await ledger.report()
            guard let self else { return }
            self.tokenReports[id] = report
            self.ledgerScans.remove(id)
        }
    }

    func start() {
        guard !started else { return }; started = true
        notifier.requestAuthorization()
        // Repairs an install that predates `.zshenv`, where the line went only to files a
        // non-interactive shell never reads. Unprompted because shell integration was
        // already accepted; it does nothing for anyone who never took it.
        if AccountService.allCases.contains(where: {
            ActiveAccountChoice.chosen($0) != nil || ActiveAccountChoice.isExplicit($0)
        }) {
            // An existing explicit "default account" choice already authorized this
            // behavior. Finish the integration for upgrades that only wrote active.sh.
            installActiveAccountShell()
        } else {
            do { try ActiveAccountShell.extendToAllShells() }
            catch { errorMessage = error.localizedDescription }
        }
        for profile in profiles where profile.service == .codex && profile.isArchived != true {
            ProfileLauncher.synchronizeCodexSettings(profile)
        }
        // The Claude half of the same job, and the one that repairs an account created
        // before the onboarding keys were carried. It has to happen here rather than in a
        // launcher: the terminal where a half-seeded account fails is a plain one the user
        // opens themselves, which never runs a Limitr script.
        for profile in profiles where profile.service == .claude && profile.isArchived != true {
            ProfileLauncher.synchronizeClaudeSettings(profile)
        }
        normalizeActiveProfiles()
        // Connectivity is unknown until the first snapshot lands, so the Codex and Claude
        // loops start empty here and are kicked off by `applyAccountSnapshots`.
        startSnapshotLoop()
        resetWatchers()
        nextCodexRefresh = .now.addingTimeInterval(60)
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.nextCodexRefresh = .now.addingTimeInterval(60)
                self?.refreshCodex()
            }
        }
        for profile in profiles where profile.service == .claude && profile.isArchived != true { refreshClaudeStatus(profile) }
        // Keep the file new shells source in step with whatever is active at launch.
        // Installing the line that sources it is not done here: it edits the user's own
        // shell profile, which is not something a first launch should decide by itself.
        // `DetectionCard` offers it instead.
        publishActiveAccount()
    }

    func refreshCodex() {
        guard codexTask == nil else { return }
        let codexProfiles = profiles.filter { $0.service == .codex && $0.isArchived != true && isConnected($0) }
        codexTask = Task { [weak self] in
            guard let self else { return }
            var codexWindows: [UsageWindow] = []
            var errors: [Error] = []
            for profile in codexProfiles {
                refreshTokenUsage(for: profile)
                guard let homePath = profile.codexHomePath else { continue }
                do {
                    let live = try await CodexLiveProvider(
                        codexHome: URL(fileURLWithPath: homePath),
                        accountID: profile.id.uuidString,
                        accountName: profile.name
                    ).fetch()
                    let localTokens = await localCodexWindows(for: profile).lazy.compactMap(\.tokenUsage).first
                    codexWindows += live.map { $0.withTokenUsage(localTokens) }
                } catch let liveError {
                    errors.append(liveError)
                    let fallback = await localCodexWindows(for: profile)
                    codexWindows += fallback.map {
                        UsageWindow(
                            source: $0.source,
                            accountID: $0.accountID,
                            accountName: $0.accountName,
                            label: $0.label,
                            usedPercent: $0.usedPercent,
                            resetsAt: $0.resetsAt,
                            windowMinutes: $0.windowMinutes,
                            staleness: .estimated,
                            tokenUsage: $0.tokenUsage
                        )
                    }
                }
            }
            let visibleCodexIDs = Set(profiles.filter { $0.service == .codex && $0.isArchived != true }.map { $0.id.uuidString })
            let visibleCodexWindows = codexWindows.filter { visibleCodexIDs.contains($0.accountID) }
            windows = windows.filter { $0.source != .codex } + visibleCodexWindows
            if !visibleCodexWindows.isEmpty && errors.isEmpty { errorMessage = nil }
            else if !visibleCodexWindows.isEmpty { errorMessage = "Live ChatGPT Codex usage is unavailable; showing a local estimate." }
            else if let error = errors.first { errorMessage = error.localizedDescription }
            notify(rules.evaluate(windows))
            codexTask = nil
        }
    }

    private func localCodexWindows(for profile: AccountProfile) async -> [UsageWindow] {
        guard let directory = profile.codexSessionsDirectory else { return [] }
        let accountID = profile.id.uuidString
        let accountName = profile.name
        return (try? await Task.detached(priority: .utility) {
            try CodexProvider(
                sessionsDirectory: directory,
                accountID: accountID,
                accountName: accountName
            ).fetch()
        }.value) ?? []
    }

    private func restartClaudeLoops() {
        let connected = profiles.filter { $0.service == .claude && $0.isArchived != true && isConnected($0) }

        for (id, task) in claudeTasks where !connected.contains(where: { $0.id == id }) {
            task.cancel()
            claudeTasks[id] = nil
            claudeDelays[id] = nil
            claudeLocalRetries[id] = nil
            accountErrors[id] = nil
            nextClaudeRefresh[id] = nil
            windows.removeAll { $0.source == .claude && $0.accountID == id.uuidString }
        }

        // Staggered across the accounts starting *now*, not across every connected one.
        // Indexing into the full list charged a reconnecting account for the accounts
        // already polling, so the one account whose usage someone was waiting on was
        // the one made to wait longest; on a reconnect this set holds a single account
        // and its first read goes out immediately.
        for (index, profile) in connected.filter({ claudeTasks[$0.id] == nil }).enumerated() {
            let id = profile.id
            let stagger = Double(index) * 7
            claudeTasks[id] = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(stagger))
                while !Task.isCancelled {
                    await self?.refreshClaude(profileID: id)
                    guard let interval = self?.nextClaudeInterval(for: id) else { return }
                    self?.nextClaudeRefresh[id] = .now.addingTimeInterval(interval)
                    try? await Task.sleep(for: .seconds(interval))
                }
            }
        }
    }

    /// Bounded on purpose: a sign-in that never lands has to settle back onto the
    /// ordinary cadence instead of retrying every few seconds for as long as it is open.
    private static let claudeLocalRetrySchedule: [TimeInterval] = [5, 10, 20, 40, 80]

    /// How long to wait before this account's next poll.
    ///
    /// Two schedules, because the two kinds of failure cost different things. The usage
    /// endpoint budgets roughly 28-30 requests per identity per rolling hour, and it is
    /// a sliding window rather than a bucket — a burst stays spent for the full hour, so
    /// anything that reached the network keeps the 180s cadence and its 429 backoff. A
    /// credential that could not be read never got that far and is free to retry, which
    /// is the difference between a reconnected account filling in within seconds and
    /// sitting blank for three minutes.
    private func nextClaudeInterval(for id: UUID) -> TimeInterval {
        if let attempt = claudeLocalRetries[id], attempt <= Self.claudeLocalRetrySchedule.count {
            return Self.claudeLocalRetrySchedule[attempt - 1]
        }
        let delay = claudeDelays[id] ?? 180
        return max(165, delay + Double.random(in: -15...15))
    }

    func refreshClaude(profileID: UUID) async {
        guard let profile = profiles.first(where: { $0.id == profileID && $0.isArchived != true }) else { return }
        refreshTokenUsage(for: profile)
        do {
            let fetched = try await ClaudeProvider(
                accountID: profile.id.uuidString,
                accountName: profile.name,
                configDirectory: profile.claudeConfigPath
            ).fetch()
            // Per-account replacement: a blanket `filter { $0.source != .claude }` would let
            // each account's refresh erase every other account's windows.
            guard profiles.contains(where: { $0.id == profileID && $0.isArchived != true }) else { return }
            windows = windows.filter { !($0.source == .claude && $0.accountID == profile.id.uuidString) } + fetched.windows
            extraUsage[profileID] = fetched.extraUsage
            claudeDelays[profileID] = 180
            claudeLocalRetries[profileID] = nil
            accountErrors[profileID] = nil
            notify(rules.evaluate(windows))
        } catch ClaudeProviderError.rateLimited {
            // Rate limiting is per access token, so only this account backs off.
            claudeLocalRetries[profileID] = nil
            claudeDelays[profileID] = min(3_600, max(360, (claudeDelays[profileID] ?? 180) * 2))
            accountErrors[profileID] = ClaudeProviderError.rateLimited.localizedDescription
        } catch ClaudeProviderError.loginRequired {
            // Limitr never refreshes the token, so a 401 means this account has to sign in
            // again. Telling the user to go and run `claude login` when the row they are
            // reading it on has a Sign in button is a dead end, so confirm it against the
            // CLI: if the login really is gone the account flips to "Not signed in" and
            // the button appears.
            claudeLocalRetries[profileID] = nil
            accountErrors[profileID] = ClaudeProviderError.loginRequired.localizedDescription
            refreshClaudeStatus(profile)
        } catch let error as ClaudeProviderError where error.isLocal {
            // A credential Limitr could not read. The request was never sent, so this
            // retries on the short schedule — see `nextClaudeInterval`. The common case
            // is a sign-in whose Keychain item lands a moment after the config file the
            // connectivity check reads, which used to cost a blank card for one poll.
            claudeLocalRetries[profileID, default: 0] += 1
            accountErrors[profileID] = error.localizedDescription
        } catch {
            claudeLocalRetries[profileID] = nil
            accountErrors[profileID] = error.localizedDescription
        }
    }

    private func refreshClaudeStatus(_ profile: AccountProfile) {
        Task { await claudeStatus(profile) }
    }

    /// Asks the CLI about one account and caches the answer.
    ///
    /// Returns it as well, so a caller that needs to know whether the probe actually
    /// answered can wait for it — `watchConnectivity` does, because ending a sign-in
    /// watch on an indeterminate reading is what left the account unexamined.
    @discardableResult
    private func claudeStatus(_ profile: AccountProfile) async -> ClaudeAccountStatus {
        let configPath = profile.claudeConfigPath
        let status = await Task.detached(priority: .utility) {
            ClaudeAccountStatus.read(configDirectory: configPath)
        }.value
        claudeStatuses[profile.id] = status
        // The status feeds the snapshot; re-reading it republishes connectivity,
        // which is what restarts the polling loops.
        refreshAccountSnapshots()
        return status
    }

    func refresh() {
        refreshCodex()
        for profile in profiles where profile.service == .claude && profile.isArchived != true && isConnected(profile) {
            let id = profile.id
            Task { await refreshClaude(profileID: id) }
        }
    }

    func canAddAccount(for service: AccountService) -> Bool {
        profiles.filter { $0.service == service && $0.isArchived != true }.count < AccountProfile.maximumPerService
    }

    func hasArchivedAccount(for service: AccountService) -> Bool {
        profiles.contains { $0.service == service && $0.isArchived == true }
    }

    func addCodexAccount() {
        guard canAddAccount(for: .codex) else {
            errorMessage = "ChatGPT Codex supports up to 3 accounts."
            return
        }
        if restoreArchivedAccount(for: .codex) { return }
        let id = UUID()
        let number = profiles.filter { $0.service == .codex && $0.isArchived != true }.count + 1
        profiles.append(AccountProfile(id: id, service: .codex, name: "ChatGPT Account \(number)", codexHomePath: AccountProfileStorage.newCodexHome(for: id).path))
        normalizeActiveProfiles()
        saveProfiles()
        resetWatchers()
        refreshAccountSnapshots()
    }

    func addClaudeAccount() {
        guard canAddAccount(for: .claude) else {
            errorMessage = "Claude Code supports up to 3 accounts."
            return
        }
        if restoreArchivedAccount(for: .claude) { return }
        let id = UUID()
        let number = profiles.filter { $0.service == .claude && $0.isArchived != true }.count + 1
        profiles.append(AccountProfile(
            id: id,
            service: .claude,
            name: "Claude Code Account \(number)",
            claudeConfigPath: AccountProfileStorage.newClaudeConfig(for: id).path
        ))
        normalizeActiveProfiles()
        saveProfiles()
        restartClaudeLoops()
        refreshAccountSnapshots()
    }

    func remove(_ profile: AccountProfile) {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        profiles[index].isArchived = true
        profiles[index].isActive = false
        connectivityWatches[profile.id]?.cancel()
        connectivityWatches[profile.id] = nil
        connectivityWatchTokens[profile.id] = nil
        accountSnapshots[profile.id] = nil
        ledgers[profile.id] = nil
        tokenReports[profile.id] = nil
        // Removing the active account leaves the service with none; hand it to whichever
        // account is still signed in rather than leaving new terminals unscoped.
        if normalizeActiveProfiles() { publishActiveAccount() }
        saveProfiles()
        refreshCodex()
        restartClaudeLoops()
        resetWatchers()
    }

    private func restoreArchivedAccount(for service: AccountService) -> Bool {
        guard let index = profiles.indices.first(where: {
            profiles[$0].service == service && profiles[$0].isArchived == true
        }) else { return false }
        profiles[index].isArchived = false
        normalizeActiveProfiles()
        saveProfiles()
        resetWatchers()
        refreshAccountSnapshots()
        return true
    }

    func nameBinding(for id: UUID) -> Binding<String> {
        Binding(
            get: { self.profiles.first(where: { $0.id == id })?.name ?? "" },
            set: { name in
                guard let index = self.profiles.firstIndex(where: { $0.id == id }) else { return }
                self.profiles[index].name = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Account" : name
                self.saveProfiles()
            }
        )
    }

    func connect(_ profile: AccountProfile) {
        guard connectivityWatches[profile.id] == nil else { return }
        accountErrors[profile.id] = nil
        // Whatever `claude auth status` last said is about to stop being true, and leaving
        // it in place is what used to strand a successful browser login.
        claudeStatuses[profile.id] = nil
        watchConnectivity(profile, until: .signedIn)
        // A disconnected account picked as the future default is now reachable: the login
        // window is in flight, so publish it without waiting for the browser round-trip.
        if normalizeActiveProfiles() { publishActiveAccount() }

        Task { [weak self] in
            guard let self else { return }
            do {
                try await Self.launch(.connect, profile: profile)
                errorMessage = nil
                resetWatchers()
                refreshAccountSnapshots()
            } catch {
                connectivityWatches[profile.id]?.cancel()
                accountErrors[profile.id] = error.localizedDescription
            }
        }
    }

    /// How many times a concluding sign-in probe may be re-asked before giving up on a
    /// definite answer. Each attempt is a subprocess, so this stays small.
    private static let statusProbeAttempts = 3

    /// Polls one account's connectivity while a sign-in or sign-out is in flight.
    ///
    /// The launcher hands the actual work to Terminal and returns immediately, so the
    /// result arrives minutes later and out of band. The ordinary snapshot loop idles at
    /// 30s whenever the Accounts window is closed, which is long enough that a finished
    /// login feels like it did not register; this watches at a couple of seconds until it
    /// sees the change, then stops.
    private func watchConnectivity(_ profile: AccountProfile, until goal: ConnectivityGoal) {
        let id = profile.id
        guard connectivityWatches[id] == nil else { return }
        let token = UUID()
        connectivityWatchTokens[id] = token
        connectivityWatches[id] = Task { @MainActor [weak self] in
            let deadline = Date.now.addingTimeInterval(600)
            while !Task.isCancelled, Date.now < deadline {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { break }
                guard let self, self.profiles.contains(where: { $0.id == id }) else { return }
                // Signing out is the case the config file cannot answer: `claude auth
                // logout` leaves `oauthAccount` behind, so only the CLI knows. Signing in
                // shows up in the file, and asking the CLI on every tick would spawn a
                // subprocess every two seconds for the whole of a browser login.
                if goal == .signedOut, profile.service == .claude { self.refreshClaudeStatus(profile) }
                self.refreshAccountSnapshots()
                guard self.isConnected(profile) == (goal == .signedIn) else { continue }
                if goal == .signedIn, profile.service == .claude {
                    // Take the reading that catches a logout the config file cannot show,
                    // and wait for it rather than firing and forgetting: a probe that
                    // could not answer is retried a few times instead of ending the watch
                    // on nothing. Bounded, because the answer is no longer load-bearing —
                    // an indeterminate status leaves the file's verdict standing.
                    for attempt in 1...Self.statusProbeAttempts {
                        if await self.claudeStatus(profile).state != .unknown { break }
                        if attempt < Self.statusProbeAttempts { try? await Task.sleep(for: .seconds(2)) }
                    }
                }
                break
            }
            guard let self else { return }
            guard self.connectivityWatchTokens[id] == token else { return }
            self.connectivityWatches[id] = nil
            self.connectivityWatchTokens[id] = nil
            // While the Terminal command is open, `settling` deliberately lets this account
            // hold the default even though it reads as disconnected. Once the command
            // finishes, is cancelled, or times out, that exception must end too. Missing
            // this normalization is what left a logged-out account in every new terminal.
            if self.normalizeActiveProfiles() { self.publishActiveAccount() }
        }
    }

    func open(_ profile: AccountProfile) {
        Task { [weak self] in
            do {
                try await Self.launch(.terminal, profile: profile)
                self?.errorMessage = nil
            } catch { self?.errorMessage = error.localizedDescription }
        }
    }

    func openYolo(_ profile: AccountProfile) {
        Task { [weak self] in
            do {
                try await Self.launch(.yolo, profile: profile)
                self?.errorMessage = nil
            } catch { self?.errorMessage = error.localizedDescription }
        }
    }

    func disconnect(_ profile: AccountProfile) {
        guard connectivityWatches[profile.id] == nil else { return }
        accountErrors[profile.id] = nil
        watchConnectivity(profile, until: .signedOut)
        Task { [weak self] in
            guard let self else { return }
            do {
                try await Self.launch(.disconnect, profile: profile)
                errorMessage = nil
                refreshAccountSnapshots()
            } catch {
                connectivityWatches[profile.id]?.cancel()
                accountErrors[profile.id] = error.localizedDescription
            }
        }
    }

    /// Filesystem preparation and `/usr/bin/open` do not belong on the main actor. The
    /// latter is also deadline-bound in `ProfileLauncher`, so a wedged LaunchServices
    /// request can neither freeze the menu nor leave a task parked forever.
    nonisolated private static func launch(_ action: ProfileLaunchAction, profile: AccountProfile) async throws {
        try await Task.detached(priority: .userInitiated) {
            switch (action, profile.service) {
            case (.connect, .codex): try ProfileLauncher.connectCodex(profile)
            case (.connect, .claude): try ProfileLauncher.connectClaude(profile)
            case (.disconnect, .codex): try ProfileLauncher.disconnectCodex(profile)
            case (.disconnect, .claude): try ProfileLauncher.disconnectClaude(profile)
            case (.terminal, .codex): try ProfileLauncher.openCodex(profile)
            case (.terminal, .claude): try ProfileLauncher.openClaude(profile)
            case (.yolo, .codex): try ProfileLauncher.openCodexYolo(profile)
            case (.yolo, .claude): try ProfileLauncher.openClaudeYolo(profile)
            }
        }.value
    }

    private func saveProfiles() { AccountProfileStorage.save(profiles) }

    /// One watcher per live account, over both services.
    ///
    /// Codex was the only service watched before, and by a watcher that could not see its
    /// files: a vnode source on `<CODEX_HOME>/sessions` reports changes to that
    /// directory's own entries, and the transcripts sit three levels below it. Measured,
    /// a nested append produced zero callbacks. Claude was never watched at all.
    private func resetWatchers() {
        watchers = profiles.compactMap { profile in
            guard profile.isArchived != true, let root = transcriptRoot(for: profile) else { return nil }
            let account = profile.id
            let source: UsageSource = profile.service == .codex ? .codex : .claude
            return TranscriptWatcher(root: root) { [weak self] in
                Task { @MainActor in self?.transcriptChanged(source: source, account: account) }
            }
        }
    }

    /// A write says an agent is working. It does not entitle us to a request.
    ///
    /// Codex reads a local file, so it may refresh immediately. Claude's 180-second floor
    /// and its 429 backoff are correctness constraints, and a filesystem event is not a
    /// reason to spend rate-limit budget — the pulse lights the notch, and the poll loop
    /// keeps its own schedule.
    private func transcriptChanged(source: UsageSource, account: UUID) {
        activity.tick(source: source, accountID: account.uuidString, at: .now)
        startActivityTicker()
        if source == .codex {
            readCodexTurn(account: account)
            refreshCodex()
        }
    }

    /// Asks Codex's own transcript whether the turn is still running.
    ///
    /// A write is only evidence about the recent past, and Codex's writes come in bursts:
    /// measured across 39 transcripts, a turn falls silent for tens of seconds at a time
    /// while the model thinks or a tool runs, so the pulse's thirty seconds expired in the
    /// middle of the work it exists to show. Codex brackets its turns — `task_started` and
    /// `task_complete` — which is the CLI saying what it is doing rather than us inferring
    /// it, so that is what the bar follows now. Claude Code writes no such marker, and
    /// `.absent` leaves it on the write-and-decay heuristic.
    ///
    /// Off the main actor because it reads the tail of a file, and the answer is applied
    /// back on it. `refreshCodex` runs alongside this rather than after: the marker is a
    /// local read and has nothing to wait for.
    private func readCodexTurn(account: UUID) {
        guard let profile = profiles.first(where: { $0.id == account }),
              let sessions = profile.codexSessionsDirectory else { return }
        Task.detached(priority: .utility) { [weak self] in
            let marker = CodexProvider(sessionsDirectory: sessions).turn()
            await MainActor.run {
                self?.activity.note(marker, source: .codex, accountID: account.uuidString, at: .now)
            }
        }
    }

    private func startActivityTicker() {
        guard activityTicker == nil else { return }
        activityTicker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pruneActivity() }
        }
    }

    /// Reassigns only when something actually expired, so an active second does not
    /// invalidate every view reading `activity` once a second for no reason.
    private func pruneActivity() {
        var pruned = activity
        pruned.prune(now: .now)
        if pruned != activity { activity = pruned }
        if pruned.isQuiet {
            activityTicker?.invalidate()
            activityTicker = nil
        }
    }

    /// Where a profile's own transcripts live. The ledger and the watcher must agree about
    /// this, so they ask the same function.
    func transcriptRoot(for profile: AccountProfile) -> URL? {
        switch profile.service {
        case .codex:
            return profile.codexSessionsDirectory
        case .claude:
            let base = profile.claudeConfigDirectory
                ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude")
            return base.appending(path: "projects")
        }
    }

    private func notify(_ alerts: [UsageAlert]) {
        for alert in alerts {
            // The same two switches gate both, which is why the decision lives in
            // `NotchPresentation` rather than here: someone who turned an alert off must
            // not be handed a panel dropping out of the ceiling in its place.
            notch?.send(.alert(alert))
            switch alert {
            case .threshold(let window, let threshold): notifier.send(title: "\(window.source.displayName) limit \(threshold)% used", body: "\(window.displayLabel) resets \(window.resetsAt.formatted(date: .omitted, time: .shortened)).", sound: threshold >= 95)
            case .reset(let window): notifier.send(title: "\(window.source.displayName) limit reset", body: "\(window.displayLabel) capacity is available again.", sound: false)
            }
        }
    }
}

/// What a `watchConnectivity` poll is waiting for.
private enum ConnectivityGoal {
    case signedIn
    case signedOut
}

private enum ProfileLaunchAction: Sendable {
    case connect
    case disconnect
    case terminal
    case yolo
}

/// One account's on-disk identity, cached by `UsageMonitor` so rendering the panel never
/// reads or parses a file.
private struct AccountSnapshot: Equatable, Sendable {
    var isConnected = false
    var email: String?
    /// Whether the credential was where the CLI keeps it — the Keychain for Claude, the
    /// account's `auth.json` for Codex. Kept beside `isConnected` rather than folded into
    /// it because a *change* here is what makes a cached `claude auth status` answer stale
    /// — see `applyAccountSnapshots`.
    var credential: CredentialPresence = .unknown
}

/// The slice of a profile the off-main snapshot read needs, so that read never reaches
/// back into `UsageMonitor` from another thread.
private struct SnapshotInput: Sendable {
    let id: UUID
    let service: AccountService
    let codexAuth: URL?
    let claudeConfig: URL?
    /// The literal `CLAUDE_CONFIG_DIR`, not the URL beside it: Claude hashes the raw
    /// string into its Keychain service name, so a standardized path finds nothing.
    let claudeConfigPath: String?
}

/// Keeps the Accounts window in front of the menu-bar panel that opened it.
///
/// The panel is an `NSPanel` at pop-up-menu level, far above an ordinary window, so the
/// Accounts window came up *behind* it. Two things are needed, and the previous version
/// only did the second reliably:
///
/// 1. Close the panel. `NSApp.keyWindow?.orderOut(nil)` at the call site only worked when
///    the panel happened to be key, which it is not when the Accounts window is reached by
///    its keyboard shortcut. The panel is `MenuBarExtraWindow`, which is no longer the
///    app's only `NSPanel`: the notch layer adds `NotchPanel`, and that one has to survive
///    the sweep, because nothing would put it back — SwiftUI restores `MenuBarExtraWindow`
///    on its own and knows nothing about ours. The two windows sitting beside them are the
///    `NSStatusBarWindow`s hosting the menu-bar icon itself, so a broader sweep — anything
///    above `.normal`, say — would take the icon down with the panel.
/// 2. Hold this window above the panel for as long as it is the one being used. The panel
///    does not always take the hint from step 1 — SwiftUI owns its visibility and puts it
///    back — and it sits at level 101, so any window that drops to `.normal` while it is
///    still up goes straight back behind it. That is what a fixed delay got wrong: the
///    level came down on a timer rather than when the window was actually finished with.
///    Tying it to key state instead keeps Accounts in front the whole time it is in use,
///    and still stops it floating over other apps once the user moves on.
struct WindowFronter: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        WindowFrontingView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// `makeNSView` can run before the view belongs to a window. Acting from
/// `viewDidMoveToWindow` guarantees the Accounts window actually exists.
final class WindowFrontingView: NSView {
    private static weak var accountsWindow: NSWindow?
    private var observers: [Any] = []

    static func bringToFront() -> Bool {
        guard let accountsWindow else { return false }
        bringToFront(accountsWindow)
        return true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        guard let window else { return }

        Self.accountsWindow = window
        Self.bringToFront(window)

        let number = window.windowNumber
        observers = [
            follow(NSWindow.didBecomeKeyNotification, windowNumber: number, level: .popUpMenu),
            follow(NSWindow.didResignKeyNotification, windowNumber: number, level: .normal)
        ]
    }

    private static func bringToFront(_ window: NSWindow) {
        for panel in NSApp.windows
        where panel !== window && panel.isVisible && panel is NSPanel && !(panel is NotchPanel) {
            panel.orderOut(nil)
        }
        window.collectionBehavior = [.moveToActiveSpace, .canJoinAllApplications, .fullScreenAuxiliary]
        NSApp.activate(ignoringOtherApps: true)
        window.level = .popUpMenu
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    /// The window is looked up by number rather than captured, because an `NSWindow` cannot
    /// cross into the `@Sendable` closure `NotificationCenter` wants.
    private func follow(_ name: Notification.Name, windowNumber: Int, level: NSWindow.Level) -> Any {
        let raw = level.rawValue
        return NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                guard let window = NSApp.window(withWindowNumber: windowNumber) else { return }
                window.level = NSWindow.Level(rawValue: raw)
            }
        }
    }
}


private final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    func requestAuthorization() { UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in } }
    func send(title: String, body: String, sound: Bool) {
        let content = UNMutableNotificationContent(); content.title = title; content.body = body; content.sound = sound ? .default : nil
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
