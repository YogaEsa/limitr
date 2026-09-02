import Foundation

/// Where Limitr puts its always-on reading.
///
/// The two are deliberately exclusive rather than two switches that can both be on. With
/// both surfaces up the same number is on screen twice — once in the menu bar and once
/// beside the notch — and the notch's own click then had to hand off to a panel that was
/// already reachable from the icon two centimetres away. One surface at a time is what
/// removes the duplicate reading and the hand-off along with it.
public enum SurfaceMode: String, CaseIterable, Sendable {
    /// The status item carries the readings; the notch layer is not installed.
    case menuBar
    /// The notch carries the readings; the status item is withdrawn from the bar entirely.
    case notch

    private static let key = "surfaceMode"

    /// Defaults to the menu bar, which is what every install already had before this
    /// setting existed: the upgrade that introduces a choice must not also make it.
    ///
    /// An unrecognised value falls back rather than trapping. The stored value is a raw
    /// string — a `defaults write` by hand, or a mode written by a later build — and the
    /// one outcome worth ruling out is an app that comes up with no surface at all.
    public static func load(from defaults: UserDefaults = AppDefaultsDomain.store()) -> SurfaceMode {
        SurfaceMode(rawValue: defaults.string(forKey: key) ?? "") ?? .menuBar
    }

    public func save(to defaults: UserDefaults = AppDefaultsDomain.store()) {
        defaults.set(rawValue, forKey: Self.key)
    }
}
