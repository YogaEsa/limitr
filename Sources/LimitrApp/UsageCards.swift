import SwiftUI
import LimitrCore

extension UsageWindow {
    /// A mark for the kind of window, not for the service — the tab above already says
    /// which product this is, so the glyph is free to distinguish session from week.
    var iconName: String {
        switch label {
        case "seven_day_opus": "diamond.fill"
        case "seven_day_sonnet": "waveform"
        default: windowMinutes <= 360 ? "clock.fill" : "calendar"
        }
    }
}

/// One rate-limit window: how full it is, when it rolls over, and whether the rate it is
/// filling at will get there early.
struct UsageCard: View {
    let window: UsageWindow
    let now: Date
    /// Change in percentage points over the last hour, or nil before there is enough
    /// history to say.
    let trend: Double?
    /// When this window would be full at the rate it has been filling, or nil when there
    /// is no wall to count down to. See `BurnRate`.
    let burnRate: BurnRate?
    let accountError: String?
    /// The user's red line. See `UsageLevel`.
    let threshold: Int

    private var level: UsageLevel { UsageLevel(usedPercent: window.usedPercent, threshold: threshold) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                CardIcon(systemImage: window.iconName, tint: level.color)
                Text(window.displayLabel)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                if window.staleness != .fresh { StalenessChip(staleness: window.staleness) }
                Spacer(minLength: 4)
                Text(Format.percent(window.usedPercent))
                    .font(.subheadline.weight(.bold).monospacedDigit())
                    .foregroundStyle(level.color)
                if let trend { TrendChip(change: trend) }
            }

            UsageBar(usedPercent: window.usedPercent, color: level.color)

            HStack(spacing: 0) {
                Group {
                    Text("Resets in ")
                    Text(Format.countdown(to: window.resetsAt, from: now)).foregroundStyle(.primary)
                    Text(" at ")
                    Text(Format.clock(window.resetsAt, from: now)).foregroundStyle(.primary)
                }
                .font(.caption)
                Spacer(minLength: 6)
                // The projection takes the pace label's place rather than a line of its
                // own. It answers the same question with a number instead of an adjective,
                // and the panel has no room to say both.
                if let burnRate {
                    Text("Full in \(Format.countdown(to: burnRate.exhaustedAt, from: now))")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(level == .critical ? Palette.critical : Palette.watch)
                        .help("At the rate this window has been filling, it reaches 100% before it resets.")
                } else if let pace = Pace(window: window, now: now, threshold: threshold) {
                    Text(pace.label)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(pace.level.color)
                }
            }
            .foregroundStyle(.secondary)

            if let accountError {
                Label(accountError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(Palette.watch)
                    .lineLimit(2)
            }
        }
        .card()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(window.displayLabel), \(Format.percent(window.usedPercent)) used, resets in \(Format.countdown(to: window.resetsAt, from: now))")
    }
}

/// Movement over the last hour. Up is spending, down is a window that rolled over.
private struct TrendChip: View {
    let change: Double

    var body: some View {
        HStack(spacing: 1) {
            Image(systemName: change > 0 ? "arrowtriangle.up.fill" : "arrowtriangle.down.fill")
                .font(.system(size: 6.5))
            Text(Format.percent(abs(change)))
        }
        .font(.caption2.weight(.semibold).monospacedDigit())
        .foregroundStyle(change > 0 ? Palette.watch : Palette.calm)
        .help("Change over the last hour")
    }
}

/// Data the app cannot vouch for has to say so on the card itself, never only in a tooltip.
private struct StalenessChip: View {
    let staleness: Staleness

    private var title: String { staleness == .estimated ? "Estimate" : "Stale" }
    private var help: String {
        staleness == .estimated
            ? "Read from the local session log because the live query failed."
            : "The newest local session log is over 30 minutes old."
    }

    var body: some View {
        Text(title)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(Palette.watch)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(Palette.watch.opacity(0.16), in: Capsule())
            .help(help)
    }
}

/// Pay-as-you-go spend past the plan's included capacity.
///
/// Only for an account that has extra usage switched on — the endpoint reports the
/// facility either way, and a permanently empty meter would be a row that costs space to
/// say nothing. No countdown, unlike every other card here: the endpoint gives this meter
/// no reset instant, and an invented one would put a clock on screen that nothing backs.
struct ExtraUsageCard: View {
    let extraUsage: ExtraUsage
    let threshold: Int

    private var level: UsageLevel { UsageLevel(usedPercent: extraUsage.utilization ?? 0, threshold: threshold) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                CardIcon(systemImage: "creditcard.fill", tint: level.color)
                Text("Extra usage")
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 4)
                if let utilization = extraUsage.utilization {
                    Text(Format.percent(utilization))
                        .font(.subheadline.weight(.bold).monospacedDigit())
                        .foregroundStyle(level.color)
                }
            }

            if let utilization = extraUsage.utilization {
                UsageBar(usedPercent: utilization, color: level.color)
            }

            if let used = extraUsage.usedCredits, let limit = extraUsage.monthlyLimit, limit > 0 {
                // "Credits" is the endpoint's own word for these two figures. What they
                // convert to is not something Limitr knows, so it does not put a currency
                // symbol in front of them.
                Text("\(Format.credits(used)) of \(Format.credits(limit)) credits used this month")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .card()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Extra usage, \(Format.percent(extraUsage.utilization ?? 0)) used")
    }
}

/// Token spend over four rolling windows, plus which models it went to.
///
/// Neither CLI serves this over an API — it is aggregated from the transcripts each one
/// writes locally, which is also why the card names its source.
struct TokenUsageCard: View {
    let report: TokenUsageReport
    let service: AccountService
    let now: Date

    private var columns: [(String, KeyPath<TokenTotals, Int>)] {
        [("In", \.inputTokens), ("Out", \.outputTokens), ("Cache", \.cacheTokens), ("Total", \.totalTokens)]
    }

    /// A partial estimate says so rather than passing an undercount off as a total.
    private func costHelp(_ cost: EstimatedCost) -> String {
        let base = "This month at API list prices. On a subscription this is not what you are billed."
        guard cost.isPartial else { return base }
        return base + " \(Format.tokens(cost.unpricedTokens)) tokens went to models with no published price and are not included."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                CardIcon(systemImage: "number", tint: service.accent)
                Text("Token usage").font(.subheadline.weight(.semibold))
                // This month's spend at list prices, in the header rather than as a fifth
                // grid column: money is the headline the card was missing, and the grid is
                // already four columns wide on a 358pt panel.
                if !report.isEmpty {
                    let cost = report.estimatedCost(for: .thisMonth)
                    Text("\(Format.dollars(cost.dollars))\(cost.isPartial ? "+" : "")")
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .help(costHelp(cost))
                }
                Spacer(minLength: 4)
                if let last = report.lastActivity {
                    Text("\(Format.countdown(to: now, from: last)) ago")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .help("Most recent turn in a local transcript")
                }
            }

            if report.isEmpty {
                Text("No local \(service.shortName) transcripts from the last 30 days.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Grid(alignment: .trailing, horizontalSpacing: 9, verticalSpacing: 5) {
                    GridRow {
                        Color.clear.frame(width: 0, height: 0).gridColumnAlignment(.leading)
                        ForEach(columns, id: \.0) { column in
                            Text(column.0.uppercased())
                                .font(.system(size: 9, weight: .semibold))
                                .tracking(0.4)
                                .foregroundStyle(.secondary)
                        }
                    }
                    ForEach(report.rows) { row in
                        GridRow {
                            Text(row.period.title)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .gridColumnAlignment(.leading)
                            ForEach(columns, id: \.0) { column in
                                Text(Format.tokens(row.totals[keyPath: column.1]))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(column.0 == "Total" ? .primary : .secondary)
                            }
                        }
                    }
                }

                if !report.models.isEmpty {
                    Divider().opacity(0.4)
                    VStack(spacing: 4) {
                        ForEach(report.models.prefix(4)) { share in
                            ModelShareRow(share: share, accent: service.accent)
                        }
                    }
                }
            }

            if !report.isEmpty {
                Text("Counted from local \(service.shortName) transcripts. The figure is what this month would have cost at API list prices — on a subscription it is not what you are billed.")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .card()
    }
}

private struct ModelShareRow: View {
    let share: ModelShare
    let accent: Color

    var body: some View {
        HStack(spacing: 8) {
            Text(share.model)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            UsageBar(usedPercent: share.share * 100, color: accent, height: 4)
                .frame(width: 54)
            Text(Format.percent(share.share * 100))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 30, alignment: .trailing)
        }
        .help("\(share.totals.totalTokens.formatted()) tokens in the last 30 days")
    }
}

/// A signed-in account that has not produced usage yet.
struct AwaitingUsageCard: View {
    let profile: AccountProfile
    let email: String?
    let open: () -> Void

    var body: some View {
        HStack(spacing: 9) {
            CardIcon(systemImage: "clock.badge.questionmark", tint: profile.service.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.name).font(.subheadline.weight(.semibold))
                if let email {
                    Text(email).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Text(profile.service == .codex
                     ? "Signed in. Usage appears after the first prompt."
                     : "Signed in. Waiting for the first usage poll.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            BarButton(systemImage: "terminal", help: "Open \(profile.service.displayName)", action: open)
        }
        .card()
    }
}

/// A service with no account signed in.
struct DisconnectedCard: View {
    let service: AccountService
    let connect: () -> Void

    var body: some View {
        VStack(spacing: 9) {
            ProductLogo(service: service, tint: .secondary)
                .frame(width: 24, height: 24)
                .opacity(0.55)
            Text("\(service.displayName) is not signed in")
                .font(.subheadline.weight(.semibold))
            Text("Sign in to start tracking this account's limits.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Sign in", action: connect)
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .card()
    }
}
