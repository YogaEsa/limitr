import SwiftUI
import LimitrCore

/// A usage bar that shimmers while its service is working.
///
/// The `TimelineView` exists only while `isWorking` is true, and that is the point: with
/// nothing running there is no timeline in the view tree at all, so the notch costs
/// nothing to leave on screen. It is also why the shimmer is scoped to this one bar rather
/// than wrapped around the panel — a timeline higher up would re-evaluate every row sixty
/// times a second in order to animate one of them.
struct ActivityBar: View {
    let percent: Double
    let color: Color
    let track: Color
    let isWorking: Bool
    /// Passed in rather than read from the environment: see `NotchController.reduceMotion`.
    let reduceMotion: Bool
    var height: CGFloat = 3
    var width: CGFloat = 26

    var body: some View {
        Capsule()
            .fill(track)
            .frame(width: width, height: height)
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(color)
                    .frame(width: max(height, width * min(1, percent / 100)))
                    .overlay { if isWorking && !reduceMotion { shimmer } }
                    .clipShape(Capsule())
            }
            .animation(.smooth(duration: 0.6), value: percent)
    }

    /// A highlight travelling the length of the fill, once every 1.6 seconds.
    ///
    /// Capped at 30fps. Unthrottled, `.animation` redraws at the display's refresh rate,
    /// which on a ProMotion Mac is 120 — and a gradient sweeping a 26-point bar once every
    /// 1.6 seconds has nothing to show for the other 90 frames. The cap is reasoning about
    /// redraw count rather than a measured saving: the uncapped version cost about 5% of a
    /// core, and `ps` averages too coarsely over a freshly launched process to say what
    /// the capped one costs by comparison.
    private var shimmer: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: false)) { context in
            let period = 1.6
            let phase = context.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: period) / period
            LinearGradient(colors: [.clear, .white.opacity(0.7), .clear],
                           startPoint: .leading, endPoint: .trailing)
                .frame(width: width * 0.45)
                .offset(x: (width + width * 0.45) * phase - width * 0.45)
                .frame(width: width, alignment: .leading)
        }
    }
}

/// The notch's own outline: square against the screen edge, rounded below.
///
/// A shape of our own rather than an `UnevenRoundedRectangle`, because the radius has to
/// grow with the panel — 12 points reads right on a 32-point strip and far too tight on a
/// 200-point one — and `UnevenRoundedRectangle`'s radii are not animatable, so it would
/// snap to the new corner partway through the spring while everything else was still
/// moving.
struct NotchSlab: Shape {
    var cornerRadius: CGFloat

    var animatableData: CGFloat {
        get { cornerRadius }
        set { cornerRadius = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let radius = max(0, min(cornerRadius, rect.height, rect.width / 2))
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radius))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - radius, y: rect.maxY),
                          control: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - radius),
                          control: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// The always-on reading: one bar per service, flanking the notch.
///
/// Deliberately small and deliberately quiet. This is the only surface in the app that is
/// on screen without being asked for, so it earns its place by being readable at a glance
/// and by never moving without a reason.
///
/// The slab it sits on is drawn by `NotchRoot`, not here: one shape serves both states so
/// it can grow between them in a single animation.
struct NotchAmbient: View {
    let summary: MenuBarSummary
    let threshold: Int
    let centerWidth: CGFloat
    /// Which services are working right now. A set rather than a flag per service, so a
    /// third service would need nothing here.
    let working: Set<UsageSource>
    let reduceMotion: Bool

    var body: some View {
        HStack(spacing: 0) {
            reading(for: .claude)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.trailing, 9)
            // The notch itself. Nothing may be drawn here — on a notched Mac it is a hole.
            Color.clear.frame(width: centerWidth)
            reading(for: .codex)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 9)
        }
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func reading(for source: UsageSource) -> some View {
        if let item = summary.items.first(where: { $0.source == source }) {
            ActivityBar(
                percent: item.percent,
                color: UsageLevel(usedPercent: item.percent, threshold: threshold).color,
                track: Palette.notchAmbientTrack,
                isWorking: working.contains(source),
                reduceMotion: reduceMotion,
                height: 4,
                width: 30
            )
            // Staleness is marked the same way, at the same value, as the menu bar marks
            // it. A stale reading presented like a live one is the claim `Staleness`
            // exists to prevent, and a third surface is a third chance to make it.
            .opacity(item.isLive ? 1 : 0.45)
        }
    }
}

/// The opened panel: one row per service, and nothing that belongs on a card.
struct NotchExpanded: View {
    let summary: NotchSummary
    let threshold: Int
    let now: Date
    let reduceMotion: Bool
    /// The band the notch occupies, left empty at the top. On a notched Mac that band is
    /// a hole in the display: a row drawn into it is invisible, not merely cramped.
    let bandHeight: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(summary.rows) { row in
                serviceRow(row)
            }
            if let working = summary.rows.first(where: \.isWorking) {
                Text("\(working.source.service.shortName) is working")
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.notchInk.opacity(0.62))
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, bandHeight + 8)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func serviceRow(_ row: NotchSummary.Row) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                ProductLogo(service: row.source.service, tint: Palette.notchInk)
                    .frame(width: 12, height: 12)
                Text(row.window.displayLabel)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Palette.notchInk.opacity(0.62))
                Spacer()
                Text(Format.percent(row.window.usedPercent))
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Palette.notchInk)
            }
            GeometryReader { proxy in
                ActivityBar(
                    percent: row.window.usedPercent,
                    color: UsageLevel(usedPercent: row.window.usedPercent, threshold: threshold).color,
                    track: Palette.notchInk.opacity(0.16),
                    isWorking: row.isWorking,
                    reduceMotion: reduceMotion,
                    height: 4,
                    width: proxy.size.width
                )
            }
            .frame(height: 4)
            HStack(spacing: 5) {
                Text("resets \(Format.countdown(to: row.window.resetsAt, from: now))")
                // The projection when there is one, since "full in about forty minutes"
                // is the sentence that changes what someone does next; the trend only
                // when there is not.
                if let burn = row.burn {
                    Text("· full \(Format.countdown(to: burn.exhaustedAt, from: now))")
                } else if let trend = row.trend {
                    Text(trend > 0 ? "· ↗ \(Format.percent(trend))" : "· ↘ \(Format.percent(-trend))")
                }
            }
            .font(.system(size: 10).monospacedDigit())
            .foregroundStyle(Palette.notchInk.opacity(0.45))
        }
        // Only `.fresh` may be presented as a live reading — the same rule, at the same
        // value, as the menu bar and the ambient strip.
        .opacity(row.window.staleness == .fresh ? 1 : 0.45)
    }
}

/// The cards, hung from the notch as the notch itself.
///
/// Square at the top and flush with the screen edge, keeping the same band clear that the
/// open strip does, and drawn on the same black — so clicking grows the notch into a
/// bigger notch rather than dropping a separate card underneath one. The notch panel is
/// ordered out while this is up, because two slabs anchored to the same edge is the break
/// this shape exists to avoid.
///
/// The slab it sits on is `NotchRoot`'s, the same one the readings sit on — which is the
/// point. The cards used to be a second `NSPanel` swapped in for the strip's, and a window
/// swap cannot be made atomic against a SwiftUI spring: whichever order the two were put
/// in, a frame arrived with the strip already gone and the cards not yet painted. Here
/// there is nothing to swap. The click changes which content the slab is drawn around, and
/// the slab grows to fit it.
///
/// Pinned to the dark colour scheme, and only this subtree is: `UsageMenu` is built from
/// `.primary`, `.secondary` and materials, every one of which resolves against the scheme
/// rather than against what it is drawn on, and on this fixed black ground the light
/// scheme is black on black. The ambient strip around it must keep resolving normally —
/// `Palette.notchAmbientSurface` is clear in the light appearance on purpose.
struct NotchCards: View {
    let monitor: UsageMonitor
    /// The band the notch occupies. On a notched Mac its top is a hole in the display, so
    /// this is empty for the same reason the open strip's is.
    let bandHeight: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: bandHeight)
            UsageMenu(monitor: monitor)
        }
        // Reported for as long as they are up, not measured once on the way in. The cards
        // change height while they are open: `UsageMenu` only draws its account tabs for a
        // service with more than one account, so moving from a service with one to a
        // service with two makes them taller — and the confirmation bars do the same. A
        // height frozen at opening time cut the difference off the bottom, which is where
        // the footer is, and the scroll view inside wraps only the cards so there was no
        // scrolling to it either.
        .background(GeometryReader { proxy in
            Color.clear.preference(key: CardsHeight.self, value: proxy.size.height)
        })
        .environment(\.colorScheme, .dark)
    }
}

/// Carries the cards' drawn height out to `NotchRoot`, and from there to the window.
private struct CardsHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// The panel's SwiftUI root, and the whole of the open/close animation.
///
/// Every state the layer has — the readings, the hover, the cards — is this one slab at a
/// different size, in one window. The window is set to fit whichever is largest *before*
/// the spring starts and never moves during it, so growing and shrinking happen entirely
/// here. That is the fix for two separate faults with one cause. The panel used to appear
/// to drop rather than grow, because an `NSWindow` frame animation on the window server's
/// timing was racing a SwiftUI content swap on another; and the cards used to blink into
/// place, because they were a second window and a window swap cannot be made atomic
/// against a spring either. Both were two timelines where the drawing needs one.
///
/// Reads `UsageMonitor` directly: it is `@Observable`, so the hosting view re-renders when
/// the readings change and at no other time. `NotchController` is observable for the same
/// reason — the state it publishes is what drives the spring.
struct NotchRoot: View {
    let monitor: UsageMonitor
    let controller: NotchController
    /// The height the readings ask for, which is the height the slab grows *from*.
    ///
    /// Measured rather than derived: it is whatever the rows come to, and that follows how
    /// many services are reporting. `NotchGeometry`'s expanded height is deliberately
    /// generous — it sizes the window, not the drawing — so using it here would start the
    /// growth from a slab taller than the one on screen.
    @State private var readingsHeight: CGFloat = 0

    private var showsCards: Bool { controller.showsCards }
    private var isExpanded: Bool { controller.state == .expanded }
    /// The cards and the hover share a ground and a corner: the cards are the open notch,
    /// carrying more.
    private var isOpen: Bool { showsCards || isExpanded }

    var body: some View {
        let slab = NotchSlab(cornerRadius: isOpen ? 22 : 12)
        // Width is driven, and so is the height once both ends of the gesture are numbers.
        // Left to hug its rows the height cannot animate at all — measured, the slab went
        // from 303×32 to 358×420 in a single layout pass — so the only motion left to see
        // was the width opening from the centre, and the cards arrived at full height in
        // one frame. Hugging is still what happens before the first measurement lands, and
        // the window's own height stays generous: the slab is what is drawn, not the
        // window, and unfilled window is transparent.
        return ZStack(alignment: .top) { content }
            .frame(width: controller.visualSize.width, alignment: .top)
            .frame(height: slabHeight, alignment: .top)
            .background(isOpen ? Palette.notchSurface : Palette.notchAmbientSurface, in: slab)
            // The content is laid out at its own natural size, which during the growth is
            // wider and taller than the slab around it. Clipping to the same shape is what
            // makes the rows appear to emerge from the notch instead of overhanging it.
            .clipShape(slab)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            // Reduce Motion is not optional politeness here. This is the only surface in
            // the app that animates without being asked, and it sits permanently in the
            // corner of someone's eye.
            .animation(controller.reduceMotion
                       ? .easeInOut(duration: 0.16)
                       : .spring(response: 0.34, dampingFraction: 0.82),
                       value: controller.state)
            // Opening the cards springs; dismissing them does not, which is why this reads
            // the destination rather than naming one animation. The window has to shrink
            // back with them, and it cannot shrink while a collapse is still being drawn
            // without clipping it — so they go at once, the way a menu dismissed by a
            // click elsewhere does.
            .animation(showsCards ? cardsAnimation : nil, value: showsCards)
            // The readings' height arrives a render *after* the state that changed it —
            // it is a measurement, and measurements come back up the tree — so it needs
            // its own trigger or the hover would grow wide on the spring and tall in one
            // jump. It also covers a row appearing or leaving while the panel is open.
            .animation(controller.reduceMotion
                       ? .easeInOut(duration: 0.16)
                       : .spring(response: 0.34, dampingFraction: 0.82),
                       value: readingsHeight)
            .onPreferenceChange(CardsHeight.self) { height in
                MainActor.assumeIsolated { controller.noteCardsHeight(height) }
            }
            .onPreferenceChange(ReadingsHeight.self) { height in
                MainActor.assumeIsolated {
                    // Only ever grows to what the readings need; the cards' own height must
                    // not be mistaken for theirs while the two are cross-fading.
                    if height > 0, !showsCards { readingsHeight = height }
                }
            }
    }

    private var cardsAnimation: Animation {
        controller.reduceMotion
            ? .easeOut(duration: 0.16)
            : .spring(response: 0.34, dampingFraction: 0.86)
    }

    /// The height the slab is drawn at: the readings' own height, or the cards'.
    ///
    /// Nil — hug the content — only until both have been measured, since an animation
    /// between a number and a hugged height has nothing to interpolate and lands in one
    /// frame. `readingsHeight` is measured here because it is a SwiftUI layout answer that
    /// changes with what is being reported; the cards' is measured by the controller,
    /// which needs the same number to size the window.
    private var slabHeight: CGFloat? {
        guard readingsHeight > 0, let cards = controller.cardsHeight else { return nil }
        return showsCards ? cards : readingsHeight
    }

    /// Asked once per render rather than stored, so it follows `activity` decaying without
    /// the view having to observe a clock of its own.
    private var working: Set<UsageSource> {
        Set(UsageSource.allCases.filter { monitor.activity.isActive(source: $0, now: .now) })
    }

    @ViewBuilder
    private var content: some View {
        if showsCards {
            // Built by the controller, which is also what measured them: the window was
            // sized from this very view, and a second construction here could differ.
            //
            // Held at their measured height rather than the slab's, so the growth clips
            // them instead of squeezing them: proposed a height that is still springing
            // open, the cards would re-lay themselves out on every frame of it.
            controller.cardsView
                .frame(height: controller.cardsHeight, alignment: .top)
                .transition(.opacity)
        } else if isExpanded {
            // The one-second tick lives here and nowhere else, and behind an `if` rather
            // than an opacity: a collapsed strip must not redraw every second for a
            // countdown that is not on screen, which is the cost the ambient state exists
            // to avoid.
            TimelineView(.periodic(from: .now, by: 1)) { context in
                NotchExpanded(summary: monitor.notchSummary,
                              threshold: monitor.preferences.redThreshold,
                              now: context.date,
                              reduceMotion: controller.reduceMotion,
                              bandHeight: controller.bandHeight)
            }
            .frame(width: controller.expandedSize.width, alignment: .top)
            .measuringHeight()
            .transition(.opacity)
        } else {
            NotchAmbient(summary: monitor.menuBarSummary,
                         threshold: monitor.preferences.redThreshold,
                         centerWidth: controller.centerWidth,
                         working: working,
                         reduceMotion: controller.reduceMotion)
                .frame(width: controller.ambientSize.width,
                       height: controller.ambientSize.height)
                .measuringHeight()
                .transition(.opacity)
        }
    }
}

/// Carries the readings' drawn height out to `NotchRoot`.
private struct ReadingsHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    /// The larger of the two while a cross-fade has both on screen — the growth must never
    /// start from a slab shorter than what is being drawn.
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private extension View {
    func measuringHeight() -> some View {
        background(GeometryReader { proxy in
            Color.clear.preference(key: ReadingsHeight.self, value: proxy.size.height)
        })
    }
}
