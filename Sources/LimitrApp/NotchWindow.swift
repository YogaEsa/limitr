import AppKit
import CoreGraphics
import Observation
import SwiftUI
import LimitrCore

/// The notch panel, as its own type.
///
/// The type is what makes it distinguishable. `WindowFronter` orders out every visible
/// `NSPanel` when the Accounts window opens, on the stated basis that the menu-bar panel
/// is the app's only one — true until this file existed. A class of its own is cheaper and
/// harder to get wrong than an identifier comparison.
final class NotchPanel: NSPanel {
    /// Key only while the cards are open.
    ///
    /// The strip must never take key: it takes no events at all in the ambient state, and
    /// becoming key would pull focus out of whatever the user is working in for a reading
    /// they did not ask to interact with. The cards are the opposite — buttons, a
    /// confirmation bar, a scroll view — and their resigning key is what closes them,
    /// which is how a menu-bar panel behaves and therefore what the click implies.
    ///
    /// Measured: a panel that refused key at first can be made key later, once this is
    /// flipped and the app is activated. The window does not have to be rebuilt for it.
    var acceptsKey = false

    override var canBecomeKey: Bool { acceptsKey }
}

@MainActor
@Observable
final class NotchController {

    private let monitor: UsageMonitor
    private var panel: NotchPanel?
    /// Whether the cards are up. Read by the panel's SwiftUI root, which draws them in
    /// place of the readings, and by `pointer(_:)`, which stands down while they are.
    private(set) var showsCards = false
    /// The height the cards asked for when they were last measured.
    ///
    /// Kept after they close rather than cleared, because it is also the height the slab
    /// *animates to*, and an animation needs a number at both ends: a height that hugs its
    /// content is not a value SwiftUI can interpolate from, so a nil here on the way in
    /// would put the cards on screen at full height in a single frame — which is what the
    /// opening looked like before this was measured. Only `showsCards` says whether they
    /// are up. Nil until the first measurement, which `install` takes.
    private(set) var cardsHeight: CGFloat?
    /// Whether the window is currently sized for the cards, which is not the same question
    /// as whether they are showing: the window has to be big before the growth starts.
    private var windowHoldsCards = false
    /// Held on its own rather than in `notifications`: it is registered and removed with
    /// the cards, on a different schedule from the ones that live as long as the layer.
    private var cardsObserver: (any NSObjectProtocol)?
    /// Kept with the centre that issued each token: `removeObserver` only undoes a
    /// registration made on the same centre, and two of these come from `NSWorkspace`'s.
    private var notifications: [(NotificationCenter, any NSObjectProtocol)] = []
    /// Separate from `notifications` because the two are torn down by different calls, and
    /// handing one to the other's remover is silent rather than an error.
    private var monitors: [Any] = []
    /// Runs only while the panel is hidden behind a fullscreen app. See `layout`.
    private var hiddenRecheck: Timer?
    /// Runs only while the panel is open, to expire an expansion the app decided on.
    private var collapseTimer: Timer?
    private var presentation = NotchPresentation()
    /// Read by the panel's SwiftUI root, which is why this type is `@Observable`.
    private(set) var state: NotchState = .ambient
    /// Tracked so a change is fed to the state machine as an event rather than silently
    /// overriding whatever state it is in.
    private var lastKnownMenuBarVisibility = true
    /// Read from `NSWorkspace` rather than through `@Environment`.
    ///
    /// `accessibilityReduceMotion` is populated by a SwiftUI scene, and this panel's
    /// `NSHostingView` is built by hand inside an `NSPanel` — the environment value never
    /// arrives, so the view read `false` no matter what the setting said and the shimmer
    /// kept running with Reduce Motion on. Published so the panel re-renders the moment
    /// the setting changes, without a relaunch.
    private(set) var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    /// The mode the layer is currently built for, so `apply` can tell a real change from a
    /// repeated assignment.
    private var installedMode: SurfaceMode?
    /// The last measurement, kept because taking one is not cheap: `metrics(for:)` asks
    /// `CGWindowListCopyWindowInfo` for the whole window list. This is read on every mouse
    /// move and several times per render, and measuring there would have put a full window
    /// enumeration behind both. Refreshed by `layout`, which is what every event that can
    /// change it already calls.
    private var cached: ScreenMetrics?

    init(monitor: UsageMonitor) {
        self.monitor = monitor
    }

    /// Called from `LimitrMenuApp.init`, which runs before `NSApplication` is up. The
    /// install is deferred one main-queue turn so `NSScreen` and the app object are both
    /// ready by the time it runs.
    func start() {
        DispatchQueue.main.async { [self] in apply(monitor.surfaceMode) }
    }

    /// Builds the layer or takes it away, according to which surface the user chose.
    ///
    /// The two surfaces are exclusive, so in menu-bar mode this is not a hidden panel: the
    /// window, its timers and its two pointer monitors all go. A global event monitor left
    /// running for a layer nobody can see is a callback on every mouse move, forever.
    func apply(_ mode: SurfaceMode) {
        guard mode != installedMode else { return }
        installedMode = mode
        if mode == .notch { install() } else { teardown() }
    }

    private func teardown() {
        closeCards()
        collapseTimer?.invalidate()
        collapseTimer = nil
        stopHiddenRecheck()
        for (center, observer) in notifications { center.removeObserver(observer) }
        notifications = []
        for pointerMonitor in monitors { NSEvent.removeMonitor(pointerMonitor) }
        monitors = []
        panel?.orderOut(nil)
        panel = nil
        presentation = NotchPresentation()
        state = presentation.state
        // Reset alongside the machine it feeds. Left at `false` — torn down while a
        // fullscreen app had the screen — a later re-install would see no *change* in
        // visibility, and so lay the freshly-reset `.ambient` state out over the
        // fullscreen window instead of hiding it.
        lastKnownMenuBarVisibility = true
    }


    private func install() {
        guard panel == nil else { return }
        let panel = NotchPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // The ambient strip overlays the application menu on the left and the status items
        // on the right. Taking their clicks would be indefensible at any level of visual
        // polish, so the panel is transparent to the mouse until it expands.
        panel.ignoresMouseEvents = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovable = false
        // 26. Measured: the panel draws over the menu-bar strip either side of the notch
        // at this level, unclipped. `mainMenu` is 24 and `statusBar` 25.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: NotchRoot(monitor: monitor, controller: self))
        self.panel = panel

        let workspace = NSWorkspace.shared.notificationCenter
        notifications = [
            (NotificationCenter.default, NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil,
                queue: .main
            ) { [self] _ in MainActor.assumeIsolated { layout() } }),
            // Entering and leaving a fullscreen space each fire this — measured, and it was
            // the one event that moved. Nothing else announces the change, so it is the
            // trigger for re-asking `isCoveredByFullScreenWindow`.
            (workspace, workspace.addObserver(
                forName: NSWorkspace.activeSpaceDidChangeNotification,
                object: nil,
                queue: .main
            ) { [self] _ in MainActor.assumeIsolated { layout() } }),
            (workspace, workspace.addObserver(
                forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
                object: nil,
                queue: .main
            ) { [self] _ in
                MainActor.assumeIsolated {
                    reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                }
            })
        ]
        layout()
        installPointerMonitors()
        // Taken once here so the *first* click has a height to animate to. Every open
        // measures again, since the cards' height follows what is connected.
        measureCards(on: screenMetrics)
    }

    /// Takes the height the cards report while they are on screen, and resizes the window
    /// to match.
    ///
    /// `measureCards` answers for the *opening* — the spring needs a destination before
    /// the cards exist — but it cannot answer for what happens after. The cards change
    /// height while they are up: `UsageMenu` draws its account tabs only for a service
    /// with more than one account, so moving from a service with one account to a service
    /// with two makes them taller, and the confirmation bars do the same. Left at the
    /// opening measurement the window cut the difference off the bottom, which is where
    /// the footer with the settings button is — and the scroll view inside the cards wraps
    /// only the cards themselves, so there was no scrolling down to it either.
    ///
    /// Not animated, and it does not need to be: the window and the slab take the new
    /// height in the same turn, so nothing is ever drawn outside the window, and the
    /// content this follows has already changed.
    func noteCardsHeight(_ height: CGFloat) {
        guard showsCards, height > 0, abs(height - (cardsHeight ?? 0)) > 0.5 else { return }
        cardsHeight = height
        layout()
    }

    /// Asks the cards how tall they want to be, off a host built only to be measured.
    ///
    /// How tall they are is their own business — it depends on how many accounts are
    /// connected and what each is reporting — and the answer is needed in two places that
    /// must agree: the window has to be big enough to hold them, and the slab has to know
    /// what height to grow to.
    private func measureCards(on metrics: ScreenMetrics) {
        let sizing = NSHostingView(rootView: cards(on: metrics))
        sizing.layoutSubtreeIfNeeded()
        cardsHeight = sizing.fittingSize.height
    }

    /// Hover cannot come from a tracking area: the collapsed panel takes no mouse events
    /// at all, on purpose, so that the menu bar underneath it keeps working. A global
    /// monitor sees the pointer without owning the pixels.
    ///
    /// Mouse events, unlike keyboard events, are not gated on the Accessibility
    /// permission. Note that this was measured from a terminal-launched build, which
    /// inherits the terminal's grant — the check that settles it is a Finder-launched
    /// bundle.
    private func installPointerMonitors() {
        let matching: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDown]
        let globalHandler: (NSEvent) -> Void = { [self] event in
            MainActor.assumeIsolated { pointer(event) }
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: matching, handler: globalHandler) {
            monitors.append(global)
        }
        // A global monitor does not see events delivered to our own application, which is
        // exactly the case once the panel has expanded and started taking clicks.
        let localHandler: (NSEvent) -> NSEvent? = { [self] event in
            MainActor.assumeIsolated { pointer(event) }
            return event
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: matching, handler: localHandler) {
            monitors.append(local)
        }
    }

    private func pointer(_ event: NSEvent) {
        // While the cards are up they are the surface being used, and they are drawn in
        // this very window — so the readings must not come back under the pointer that is
        // reading them.
        guard !showsCards else { return }
        let measured = screenMetrics
        let target: NotchState = presentation.state == .expanded ? .expanded : .ambient
        // A few points of slack above and below, so the strip is reachable without
        // demanding pixel accuracy against the top edge of the screen.
        let strip = NotchGeometry.frame(for: target, on: measured).insetBy(dx: 0, dy: -6)
        let inside = strip.contains(NSEvent.mouseLocation)

        switch event.type {
        case .leftMouseDown where inside:
            // The notch is a reading; everything it deliberately leaves out lives on the
            // cards. `send` returns the readings to ambient, which is the state the strip
            // comes back to when the cards are dismissed.
            send(.clicked)
            openCards()
        case .mouseMoved:
            send(inside ? .pointerEntered : .pointerExited)
        default:
            break
        }
    }

    /// The cards, drawn in the strip's own window.
    ///
    /// In notch mode there is no status item to click, which is the whole point of the
    /// mode — and it is also what retired the previous hand-off: reaching `MenuBarExtra`'s
    /// button meant matching an internal `NSStatusBarWindow` class by name and hoping a
    /// macOS release had not restructured it. Hosting `UsageMenu` here is the same content
    /// with none of that.
    ///
    /// They were a second panel until the blink made the case against it. A window becomes
    /// visible before the view inside it has drawn — measured on the old sequence, 22ms,
    /// one to two display frames — so the strip was always taken away either too early
    /// (nothing on screen for a frame) or too late (the strip visibly collapsing first).
    /// The system's window fade had been covering it, which is why it only appeared when
    /// the fade came off. Two windows cannot be exchanged atomically against one SwiftUI
    /// spring, so there is one window, and the cards are a state of the same slab.
    ///
    /// What the window does have to do is grow, because the cards are taller than the
    /// strip. It grows *before* the spring starts and never during it: a window larger
    /// than its drawing leaves transparent area behind, which costs nothing to look at,
    /// while a window smaller than its drawing cuts it off.
    private func openCards() {
        guard !showsCards, let panel else { return }
        let measured = screenMetrics

        measureCards(on: measured)
        // The window first, the growth second — in that order and in this one turn, so the
        // spring never draws into a window that has not been made room for.
        windowHoldsCards = true
        layout()
        showsCards = true

        cardsObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: panel,
            queue: .main
        ) { [self] _ in MainActor.assumeIsolated { closeCards() } }

        // The cards carry controls, so unlike the strip this window has to take key — and
        // activating is what actually hands it over, an accessory app's panel included.
        panel.acceptsKey = true
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    /// Closing is deliberately not the opening in reverse.
    ///
    /// The window has to shrink back with the cards, and it cannot shrink *during* a
    /// collapse without clipping the slab it is still drawing — so the cards go at once,
    /// the way a menu dismissed by a click elsewhere does, and the window follows in the
    /// same breath. `NotchRoot` is what withholds the animation in this direction.
    private func closeCards() {
        guard showsCards else { return }
        showsCards = false
        windowHoldsCards = false
        if let cardsObserver { NotificationCenter.default.removeObserver(cardsObserver) }
        cardsObserver = nil
        panel?.acceptsKey = false
        layout()
        // Hands focus back to whatever the user was in. Ordering the window out is what
        // used to do this, and is no longer available: it is the strip's window too.
        //
        // Only when nothing of ours took key in its place, and asked a turn later because
        // at the moment key is resigned the window taking it has not been recorded yet.
        // The Settings window is opened from these very cards, and deactivating on the way
        // out would drop it behind whatever the user had in front.
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                if NSApp.keyWindow == nil { NSApp.deactivate() }
            }
        }
    }

    /// The cards' view, built in one place so the host that measures them and the panel
    /// that draws them cannot drift apart.
    private func cards(on metrics: ScreenMetrics) -> some View {
        NotchCards(monitor: monitor, bandHeight: NotchGeometry.bandHeight(metrics))
            .frame(width: NotchGeometry.frame(for: .expanded, on: metrics).width)
    }


    func send(_ event: NotchPresentation.Event) {
        // Alerts are posted whichever surface the user chose, so in menu-bar mode they
        // arrive here with nothing to drive. Answering them would leave a collapse timer
        // ticking for a panel that does not exist.
        guard installedMode == .notch else { return }
        let before = presentation.state
        presentation.handle(event, now: .now, preferences: monitor.preferences)
        guard presentation.state != before else { return }
        state = presentation.state
        layout(state: presentation.state)
        // One timer, and only while an auto-collapse can still be pending.
        if presentation.state == .expanded {
            collapseTimer?.invalidate()
            collapseTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [self] _ in
                MainActor.assumeIsolated { send(.tick(.now)) }
            }
        } else {
            collapseTimer?.invalidate()
            collapseTimer = nil
        }
    }

    /// The built-in display when there is one, because that is where the notch is.
    private func targetScreen() -> NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main
    }

    private func metrics(for screen: NSScreen) -> ScreenMetrics {
        let auxiliary: ScreenMetrics.Auxiliary? = {
            guard let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea
            else { return nil }
            return ScreenMetrics.Auxiliary(left: left.width, right: right.width)
        }()
        return ScreenMetrics(
            frame: screen.frame,
            topInset: screen.safeAreaInsets.top,
            auxiliary: auxiliary,
            menuBarIsVisible: !isCoveredByFullScreenWindow(screen)
        )
    }

    /// Whether an ordinary window is covering this screen entirely — the fullscreen case.
    ///
    /// Asked of the window list rather than of the screen, because every screen-side answer
    /// is blind to it. While a genuine fullscreen window was up, `NSScreen.visibleFrame`
    /// still reported its 34-point menu-bar gap, `NSMenu.menuBarVisible()` still returned
    /// true, and the Window Server's own menu-bar window stayed in the on-screen list. A
    /// window whose bounds equal the whole display, menu-bar strip included, was the only
    /// signal that moved.
    ///
    /// This is load-bearing rather than defensive: `.canJoinAllSpaces` carries the panel
    /// into the fullscreen space, so without it the panel would sit over a fullscreen video
    /// for as long as it played.
    private func isCoveredByFullScreenWindow(_ screen: NSScreen) -> Bool {
        // `CGWindowListCopyWindowInfo` reports top-left-origin coordinates anchored on the
        // origin screen, so a secondary display's rect has to be flipped into that space.
        guard let origin = NSScreen.screens.first else { return false }
        let full = CGRect(
            x: screen.frame.minX,
            y: origin.frame.maxY - screen.frame.maxY,
            width: screen.frame.width,
            height: screen.frame.height
        )
        let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] ?? []
        return list.contains { info in
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = bounds["X"], let y = bounds["Y"],
                  let w = bounds["Width"], let h = bounds["Height"]
            else { return false }
            return CGRect(x: x, y: y, width: w, height: h).equalTo(full)
        }
    }

    /// Recomputed on every screen change, every space change, and every state change.
    func layout(state: NotchState? = nil) {
        guard let panel, let screen = targetScreen() else { return }
        let measured = metrics(for: screen)
        cached = measured

        // Visibility goes in as an event rather than overriding the state here, so that
        // the machine owns the rule about what may happen while the screen is taken.
        if measured.menuBarIsVisible != lastKnownMenuBarVisibility {
            lastKnownMenuBarVisibility = measured.menuBarIsVisible
            send(.menuBarVisibilityChanged(measured.menuBarIsVisible))
            return
        }

        let resolved = state ?? presentation.state
        guard resolved != .hidden else {
            panel.orderOut(nil)
            startHiddenRecheck()
            return
        }
        stopHiddenRecheck()

        // Interactive only once it hangs below the menu bar over ordinary app content.
        // Transparent is not the same as absent: measured, a click in the empty part of
        // this window is routed to it rather than through it, so the window may only be
        // interactive where it actually draws.
        panel.ignoresMouseEvents = resolved != .expanded && !windowHoldsCards

        // Set without animation, and always at least as large as what is drawn. What
        // grows is the slab inside it — see `NotchRoot`.
        let target = windowHoldsCards
            ? cardsHeight.map { NotchGeometry.windowFrame(cardsHeight: $0, on: measured) }
                ?? NotchGeometry.windowFrame(on: measured)
            : NotchGeometry.windowFrame(on: measured)
        if !panel.frame.equalTo(target) { panel.setFrame(target, display: false) }
        panel.orderFrontRegardless()
    }

    /// Asks again, slowly, for as long as the panel is hidden.
    ///
    /// `activeSpaceDidChangeNotification` fires while the fullscreen transition is still
    /// animating, so the window list still holds the fullscreen window at the moment the
    /// notification arrives. Laying out once on that signal hides the panel correctly on
    /// the way in and then never brings it back on the way out — which is exactly what
    /// happened. The notification stays as the prompt reaction; this is what makes the
    /// answer eventually right.
    private func startHiddenRecheck() {
        guard hiddenRecheck == nil else { return }
        hiddenRecheck = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [self] _ in
            MainActor.assumeIsolated { layout() }
        }
    }

    private func stopHiddenRecheck() {
        hiddenRecheck?.invalidate()
        hiddenRecheck = nil
    }

    /// The measurement the view draws against, taking one only if `layout` has not yet.
    private var screenMetrics: ScreenMetrics {
        if let cached { return cached }
        guard let screen = targetScreen() else {
            return ScreenMetrics(frame: .zero, topInset: 0, auxiliary: nil, menuBarIsVisible: true)
        }
        let measured = metrics(for: screen)
        cached = measured
        return measured
    }

    var centerWidth: CGFloat { NotchGeometry.centerWidth(screenMetrics) }

    /// See `NotchGeometry.bandHeight`. The open panel leaves this much clear at the top.
    var bandHeight: CGFloat { NotchGeometry.bandHeight(screenMetrics) }

    /// What the slab draws at right now — the part of the window that is filled, and
    /// animating it is the whole open/close gesture.
    ///
    /// The cards take the open strip's width rather than the state's: the click sends the
    /// readings back to `.ambient` underneath, since that is where they must be when the
    /// cards are dismissed, and the slab would otherwise narrow to the ambient width with
    /// the cards still drawn inside it.
    var visualSize: CGSize {
        showsCards
            ? NotchGeometry.frame(for: .expanded, on: screenMetrics).size
            : NotchGeometry.frame(for: state, on: screenMetrics).size
    }

    /// The cards, at the size and on the measurements the window was built for.
    var cardsView: some View { cards(on: screenMetrics) }

    var ambientSize: CGSize { NotchGeometry.frame(for: .ambient, on: screenMetrics).size }

    var expandedSize: CGSize { NotchGeometry.frame(for: .expanded, on: screenMetrics).size }
}
