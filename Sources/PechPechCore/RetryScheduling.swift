/// Hosts select how a running node receives retry opportunities. This does not
/// grant operating-system execution time or enable platform background modes.
public enum RetryScheduling: Equatable, Sendable {
    /// Retry each second while the process is scheduled by its operating system.
    case periodic
    /// Service link events and explicit tick calls without a periodic task.
    case eventDriven
}
