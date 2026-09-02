import AppKit
import SwiftUI
import LimitrCore

// MARK: - Palette

/// The panel's colours.
///
/// Deliberately literal rather than semantic. The panel floats on the menu-bar's vibrancy
/// material, where `.controlBackgroundColor` and friends resolve to a flat grey that sits
/// visibly on top of the blur instead of inside it. Opacity-based tints of `.primary`
/// blend with whatever is behind the panel and stay legible in both appearances.
enum Palette {
    /// Each service's own mark, so a tab's colour is recognisable before its label is read.
    static let claude = Color(red: 0.851, green: 0.467, blue: 0.341)
    static let codex = Color(red: 0.063, green: 0.639, blue: 0.498)

    /// The usage ramp. `critical` starts at the same percentage that sends a notification —
    /// a bar and an alert must never disagree about what counts as trouble.
    static let calm = Color(red: 0.176, green: 0.678, blue: 0.420)
    static let watch = Color(red: 0.902, green: 0.639, blue: 0.200)
    static let critical = Color(red: 0.851, green: 0.278, blue: 0.251)

    static let cardFill = Color.primary.opacity(0.05)
    static let cardStroke = Color.primary.opacity(0.07)
    static let railFill = Color.primary.opacity(0.06)
    static let trackFill = Color.primary.opacity(0.10)

    /// The open notch panel's surface and ink.
    ///
    /// Black in both appearances, deliberately not theme-following. The open panel hangs
    /// below the menu bar over whatever application is running, so it needs a ground of
    /// its own; and on a notched Mac its top edge meets a physical hole, which is black in
    /// light mode too. A surface that followed the theme would meet that hole at a visible
    /// seam half the time. On a Mac with no notch the same black draws the virtual pill.
    ///
    /// Because the surface is fixed rather than resolved, nothing drawn on it may use
    /// `.primary`, `.secondary` or `.tertiary`: those resolve against the *system*
    /// appearance, so in light mode they would put black text on black. Everything on the
    /// layer is an opacity of `notchInk`.
    static let notchSurface = Color.black
    static let notchInk = Color.white

    /// The ambient strip's ground, which — unlike the open panel's — does follow the bar.
    ///
    /// Clear in the light appearance. The strip sits *inside* the menu bar rather than
    /// below it, and there a fixed black is not the notch extended, it is a black box
    /// parked in a light menu bar with the wallpaper visible either side of it. Going
    /// clear lets the two readings sit in the bar the way the status items beside them do.
    /// In the dark appearance the black still earns its place: it merges the strip into
    /// the hole it flanks.
    static let notchAmbientSurface = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .black : .clear
    })

    /// The unfilled part of an ambient reading's bar, against whichever ground it landed
    /// on. `notchInk` cannot serve here for the same reason the surface cannot: at 24%
    /// white it is invisible on a light menu bar.
    static let notchAmbientTrack = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.24)
            : NSColor(white: 0, alpha: 0.22)
    })

    /// The selected pill on a segmented rail.
    ///
    /// Not `.background`: that resolves to the window's own colour, which in dark mode is
    /// the same near-black as the rail it is supposed to sit on top of, leaving selection
    /// legible only from its border. White at two different alphas lifts in both
    /// appearances, so the same shape reads as raised either way.
    static let elevatedFill = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.13)
            : NSColor(white: 1, alpha: 0.95)
    })
}

extension AccountService {
    var displayName: String { self == .codex ? "ChatGPT Codex" : "Claude Code" }
    var shortName: String { self == .codex ? "Codex" : "Claude" }
    /// What the tab calls it: the product people say out loud, not the CLI's full name.
    var tabName: String { self == .codex ? "ChatGPT" : "Claude" }
    var accent: Color { self == .codex ? Palette.codex : Palette.claude }
}

extension UsageSource {
    var service: AccountService { self == .codex ? .codex : .claude }
    var displayName: String { service.displayName }
}

// MARK: - Usage severity

/// Where a window sits on the usage ramp.
enum UsageLevel {
    case calm
    case watch
    case critical

    /// - Parameter threshold: the user's red line, which is also the point their
    ///   notification fires at. One number does both jobs so a bar and an alert can never
    ///   disagree about what counts as trouble.
    init(usedPercent: Double, threshold: Int) {
        let red = Double(threshold)
        // Amber sits proportionally below the red line rather than at a fixed 70, so a
        // user who moves the line down still gets a warning band instead of jumping
        // straight from calm to critical. At the default 85 this lands on 70, which is
        // where the band has always been.
        if usedPercent >= red { self = .critical }
        else if usedPercent >= red * 0.82 { self = .watch }
        else { self = .calm }
    }

    var color: Color {
        switch self {
        case .calm: Palette.calm
        case .watch: Palette.watch
        case .critical: Palette.critical
        }
    }
}

/// How a window's burn rate compares with its own clock.
///
/// A percentage on its own does not answer the question the panel exists for: 71% is
/// comfortable six days into a week and alarming six hours in. Comparing spend against
/// elapsed time is the cheapest honest way to say which one it is.
struct Pace {
    let label: String
    let level: UsageLevel

    /// - Returns: nil while the window is too young to project from, where any rate would
    ///   be noise rather than a signal.
    init?(window: UsageWindow, now: Date, threshold: Int) {
        let total = Double(window.windowMinutes) * 60
        guard total > 0 else { return nil }
        let remaining = max(0, window.resetsAt.timeIntervalSince(now))
        let elapsed = (total - remaining) / total
        guard elapsed > 0.08 else { return nil }

        if window.usedPercent >= Double(threshold) {
            self = Pace(label: "Near limit", level: .critical)
            return
        }
        switch window.usedPercent / 100 / elapsed {
        case ..<1.05: self = Pace(label: "On track", level: .calm)
        case ..<1.4: self = Pace(label: "Above pace", level: .watch)
        default: self = Pace(label: "Burning fast", level: .critical)
        }
    }

    private init(label: String, level: UsageLevel) {
        self.label = label
        self.level = level
    }
}

// MARK: - Formatting

enum Format {
    /// "2h 48m", "3d 8h", "12m" — the coarsest pair of units that still says something.
    static func countdown(to date: Date, from now: Date) -> String {
        let minutes = Int(max(0, date.timeIntervalSince(now)) / 60)
        let (days, remainder) = (minutes / 1_440, minutes % 1_440)
        let (hours, rest) = (remainder / 60, remainder % 60)
        if days > 0 { return hours > 0 ? "\(days)d \(hours)h" : "\(days)d" }
        if hours > 0 { return "\(hours)h \(rest)m" }
        return minutes > 0 ? "\(minutes)m" : "under a minute"
    }

    /// The reset instant, at the smallest precision that still identifies it.
    static func clock(_ date: Date, from now: Date, calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return date.formatted(.dateTime.hour().minute()) }
        if date.timeIntervalSince(now) < 6 * 86_400 {
            return date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
        }
        return date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }

    static func seconds(to date: Date, from now: Date) -> String {
        let seconds = Int(max(0, date.timeIntervalSince(now)))
        return seconds < 90 ? "\(seconds)s" : countdown(to: date, from: now)
    }

    static func tokens(_ value: Int) -> String {
        value == 0 ? "—" : value.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)))
    }

    static func percent(_ value: Double) -> String {
        "\(Int(value.rounded()))%"
    }

    /// A cost estimate, at the precision the size of it warrants.
    static func dollars(_ value: Double) -> String {
        if value >= 1_000 { return "$\((value / 1_000).formatted(.number.precision(.fractionLength(1))))k" }
        if value >= 100 { return "$\(value.formatted(.number.precision(.fractionLength(0))))" }
        return "$\(value.formatted(.number.precision(.fractionLength(2))))"
    }

    /// Extra-usage credit figures. Compact, and deliberately without a currency symbol —
    /// the endpoint does not say what unit these are in.
    static func credits(_ value: Double) -> String {
        value.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)))
    }
}

// MARK: - Surfaces

private struct CardSurface: ViewModifier {
    let padding: CGFloat

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.cardFill, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .strokeBorder(Palette.cardStroke, lineWidth: 0.75)
            }
    }
}

extension View {
    func card(padding: CGFloat = 11) -> some View { modifier(CardSurface(padding: padding)) }
}

/// A glyph in a tinted rounded square — the panel's one repeated ornament, used to give
/// every card the same left edge.
struct CardIcon: View {
    let systemImage: String
    let tint: Color

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 20, height: 20)
            .background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

struct UsageBar: View {
    let usedPercent: Double
    let color: Color
    var height: CGFloat = 6
    /// Overridable for the notch, whose surface is forced to black or white: the default
    /// is an opacity of `.primary`, which resolves against the system appearance and so
    /// vanishes into that surface exactly when the appearances disagree.
    var track: Color = Palette.trackFill

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(track)
                Capsule()
                    .fill(color.gradient)
                    .frame(width: max(usedPercent > 0 ? height : 0, proxy.size.width * min(1, usedPercent / 100)))
            }
        }
        .frame(height: height)
        .animation(.easeOut(duration: 0.35), value: usedPercent)
    }
}

// MARK: - Product marks

/// The two marks, loaded once.
///
/// Flat white on a tight viewBox, which is what lets them be drawn as templates: macOS
/// keeps only the alpha, so one asset takes whatever colour the surface it lands on is
/// using — the accent on a card, the ink on the notch, black inside the menu bar's
/// template rendering. They were traced bitmaps before, 250KB of near-identical paths in
/// a canvas half again as wide as the glyph, and the Claude one was a filled orange tile
/// that collapsed to a solid square the moment it was tinted.
@MainActor
enum ProductLogoAssets {
    static let codex = load("gpticon")
    static let claude = load("claudeicon")

    static func image(for service: AccountService) -> NSImage? {
        service == .codex ? codex : claude
    }

    private static func load(_ resource: String) -> NSImage? {
        let bundledURL = Bundle.main.url(forResource: resource, withExtension: "svg")
        let developmentURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Resources/Assets/\(resource).svg")
        return NSImage(contentsOf: bundledURL ?? developmentURL)
    }
}

/// Each service's mark, drawn as one tintable glyph so a row of them reads as a set.
struct ProductLogo: View {
    let service: AccountService
    var tint: Color?

    var body: some View {
        Group {
            if let image = ProductLogoAssets.image(for: service) {
                Image(nsImage: image)
                    .resizable()
                    .renderingMode(.template)
                    .foregroundStyle(tint ?? .primary)
                    .scaledToFit()
            } else {
                Image(systemName: "circle.hexagongrid")
                    .resizable()
                    .foregroundStyle(tint ?? .primary)
                    .scaledToFit()
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Segmented service tabs

/// The moving part of a segmented rail: the raised pill under whatever is selected.
///
/// One view handed between slots via `matchedGeometryEffect`, so switching reads as a
/// single object sliding across rather than two shapes cross-fading. Both rails on the
/// panel use it, which is what makes the account row feel like the service row.
private struct SelectionPill: View {
    let accent: Color
    let cornerRadius: CGFloat
    let namespace: Namespace.ID
    let id: String

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Palette.elevatedFill)
            .shadow(color: .black.opacity(0.14), radius: 2.5, y: 1)
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(accent.opacity(0.45), lineWidth: 1)
            }
            .matchedGeometryEffect(id: id, in: namespace)
    }
}

private extension Animation {
    /// Shared by both rails so the two selections move with the same hand.
    static let railSlide = Animation.snappy(duration: 0.25, extraBounce: 0.08)
}

/// The panel's top-level switch, one pill per service.
struct ServiceTabs: View {
    let services: [AccountService]
    @Binding var selection: AccountService
    @Namespace private var pill

    var body: some View {
        HStack(spacing: 2) {
            ForEach(services, id: \.self) { service in
                let isSelected = selection == service
                Button {
                    withAnimation(.railSlide) { selection = service }
                } label: {
                    HStack(spacing: 6) {
                        // Both marks take the same ink. Colour belongs to the pill's border
                        // here; two brand colours side by side made the row read as two
                        // unrelated buttons rather than one switch.
                        ProductLogo(service: service, tint: isSelected ? .primary : .secondary)
                            .frame(width: 16, height: 16)
                        Text(service.tabName)
                            .font(.callout.weight(isSelected ? .semibold : .medium))
                    }
                    .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 30)
                    .background {
                        if isSelected {
                            SelectionPill(accent: service.accent, cornerRadius: 9, namespace: pill, id: "service")
                        }
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help(service.displayName)
                .accessibilityLabel(service.displayName)
                .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
            }
        }
        .padding(3)
        .background(Palette.railFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// One account per pill, shown only when a service has more than one.
struct AccountTabs: View {
    let profiles: [AccountProfile]
    let selectedID: UUID?
    let accent: Color
    let isConnected: (AccountProfile) -> Bool
    /// The account the menu-bar title summarises and new shells inherit. Deliberately
    /// separate from `selectedID`, which is only what the panel is showing right now.
    let isActive: (AccountProfile) -> Bool
    let peakPercent: (AccountProfile) -> Double?
    let select: (AccountProfile) -> Void
    @Namespace private var pill

    private func help(for profile: AccountProfile) -> String {
        let connection = isConnected(profile) ? "Signed in" : "Not signed in"
        return isActive(profile) ? "\(connection) · default account" : connection
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(profiles) { profile in
                let isSelected = selectedID == profile.id
                Button {
                    withAnimation(.railSlide) { select(profile) }
                } label: {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(isConnected(profile) ? Palette.calm : Color.secondary.opacity(0.5))
                            .frame(width: 6, height: 6)
                        Text(profile.name)
                            .font(.caption.weight(isSelected ? .semibold : .regular))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        if let peak = peakPercent(profile) {
                            Text(Format.percent(peak))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        if isActive(profile) {
                            Image(systemName: "star.fill")
                                .font(.system(size: 7))
                                .foregroundStyle(accent)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .padding(.horizontal, 4)
                    .background {
                        if isSelected {
                            SelectionPill(accent: accent, cornerRadius: 8, namespace: pill, id: "account")
                        }
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help(help(for: profile))
            }
        }
        .padding(3)
        .background(Palette.railFill, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    }
}
