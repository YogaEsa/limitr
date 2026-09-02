import Foundation

/// Which accounts signed in between two readings of connectivity.
///
/// Split out of the app because the interesting half is what it refuses to report. A
/// *state* of "something is connected" cannot close the welcome screen: the common first
/// run is someone already signed in at the default paths, so that state is true from the
/// very first poll and the screen would be gone before the user had answered it — taking
/// with it the scan that finds a login living somewhere custom. A *transition* is the
/// honest signal, and a first reading is not one.
public enum ConnectivityTransition {
    /// - Parameters:
    ///   - previous: the last reading, keyed by account. An account absent from it has not
    ///     been read yet, which is why it can never count as having just signed in.
    ///   - current: the reading that just landed.
    /// - Returns: the accounts that went from a known-disconnected reading to a connected
    ///   one.
    public static func newlyConnected(previous: [UUID: Bool], current: [UUID: Bool]) -> Set<UUID> {
        Set(current.filter { id, isConnected in isConnected && previous[id] == false }.keys)
    }
}
