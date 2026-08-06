import Foundation

/// Races `operation` against an explicit deadline. `URLSessionConfiguration.timeoutIntervalForRequest`
/// only fires when no bytes arrive for the interval — a connection that trickles data
/// indefinitely never trips it, so an unguarded fetch can hang well past its declared timeout
/// and leave a loading spinner stuck. Wrapping a fetch here guarantees it always resolves.
func withDeadline<T: Sendable>(
    seconds: TimeInterval,
    onTimeout: @escaping @Sendable () -> Error,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw onTimeout()
        }
        defer { group.cancelAll() }
        guard let result = try await group.next() else {
            throw onTimeout()
        }
        return result
    }
}
