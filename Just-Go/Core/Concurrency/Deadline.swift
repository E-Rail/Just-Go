import Foundation

/// Races `operation` against an explicit deadline. A session's `timeoutIntervalForRequest` only
/// fires when no bytes arrive, so a connection that trickles data never trips it and an unguarded
/// fetch can hang past its timeout.
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
