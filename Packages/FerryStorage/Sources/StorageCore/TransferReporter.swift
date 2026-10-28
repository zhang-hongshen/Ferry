import Foundation
import Synchronization

/// Options for a single upload or download.
public struct TransferOptions: Sendable, Hashable {
    /// Continue a previous attempt instead of starting over, when the provider supports it.
    public var resume: Bool
    /// Opaque provider state from a previous attempt (an S3 upload ID or ETag, for example).
    public var resumeToken: String?

    public init(resume: Bool = false, resumeToken: String? = nil) {
        self.resume = resume
        self.resumeToken = resumeToken
    }
}

/// Collects progress from a provider, enforces the bandwidth limit, and records resume state.
///
/// Providers call `throttle(_:)` before moving a chunk and `record(_:)` once bytes are moved.
public final class TransferReporter: Sendable {
    public struct Snapshot: Sendable {
        public var completedBytes: Int64
        public var totalBytes: Int64?
    }

    private struct State {
        var completed: Int64 = 0
        var total: Int64?
        var lastEmit: ContinuousClock.Instant?
    }

    private let state = Mutex(State())
    private let limiter: BandwidthLimiter?
    private let onProgress: @Sendable (Snapshot) -> Void
    private let onResumeToken: @Sendable (String?) -> Void
    private let minimumInterval: Duration

    public init(
        limiter: BandwidthLimiter? = nil,
        minimumInterval: Duration = .milliseconds(200),
        onProgress: @escaping @Sendable (Snapshot) -> Void = { _ in },
        onResumeToken: @escaping @Sendable (String?) -> Void = { _ in }
    ) {
        self.limiter = limiter
        self.minimumInterval = minimumInterval
        self.onProgress = onProgress
        self.onResumeToken = onResumeToken
    }

    public var snapshot: Snapshot {
        state.withLock { Snapshot(completedBytes: $0.completed, totalBytes: $0.total) }
    }

    public func setTotal(_ total: Int64?) {
        state.withLock { $0.total = total }
        emit(force: true)
    }

    /// Sets the absolute number of completed bytes, for example after resuming.
    public func setCompleted(_ completed: Int64) {
        state.withLock { $0.completed = completed }
        emit(force: true)
    }

    /// Adds transferred bytes. Negative values roll back progress of a failed attempt.
    public func record(_ bytes: Int64) {
        state.withLock { $0.completed += bytes }
        emit(force: false)
    }

    /// Waits until the bandwidth limit allows moving `bytes`, and checks for cancellation.
    public func throttle(_ bytes: Int) async throws {
        try Task.checkCancellation()
        try await limiter?.consume(bytes)
    }

    public func updateResumeToken(_ token: String?) {
        onResumeToken(token)
    }

    private func emit(force: Bool) {
        let now = ContinuousClock.now
        let snapshot: Snapshot? = state.withLock { state in
            if !force, let last = state.lastEmit, now - last < minimumInterval,
               state.completed != state.total {
                return nil
            }
            state.lastEmit = now
            return Snapshot(completedBytes: state.completed, totalBytes: state.total)
        }
        if let snapshot {
            onProgress(snapshot)
        }
    }
}

/// A shared token-bucket limiter. A rate of zero means unlimited.
public actor BandwidthLimiter {
    private var bytesPerSecond: Int
    private var nextAvailable = ContinuousClock.now

    public init(bytesPerSecond: Int = 0) {
        self.bytesPerSecond = bytesPerSecond
    }

    public func setRate(bytesPerSecond: Int) {
        self.bytesPerSecond = max(0, bytesPerSecond)
        nextAvailable = .now
    }

    public func consume(_ bytes: Int) async throws {
        guard bytesPerSecond > 0, bytes > 0 else { return }
        let now = ContinuousClock.now
        let start = max(now, nextAvailable)
        nextAvailable = start + .seconds(Double(bytes) / Double(bytesPerSecond))
        if start > now {
            try await Task.sleep(until: start, clock: .continuous)
        }
    }
}
