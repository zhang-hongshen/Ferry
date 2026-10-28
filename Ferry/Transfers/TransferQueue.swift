import AppKit
import Foundation
import Observation
import StorageCore

/// Runs uploads, downloads, and cross-connection copies with a concurrency limit, automatic
/// retries, and a shared bandwidth limit. Unfinished jobs resume on the next launch.
///
/// Finished jobs leave the queue. Uploads show their progress in the browser; downloads publish
/// theirs to Finder on the local file.
@Observable
final class TransferQueue {
    static let uploadDidFinish = Notification.Name("TransferQueueUploadDidFinish")

    private(set) var jobs: [TransferJob] = []
    /// The last download that failed after its retries, for the window to show.
    var downloadError: PresentableError?

    @ObservationIgnored private let store: ConnectionStore
    @ObservationIgnored private let pool: ConnectionPool
    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private let limiter = BandwidthLimiter()
    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []

    init(store: ConnectionStore, pool: ConnectionPool,
         fileURL: URL = AppDirectories.applicationSupport.appending(path: "transfers.json")) {
        self.store = store
        self.pool = pool
        self.fileURL = fileURL
        load()
        applySettings()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UserDefaults.didChangeNotification, object: nil,
                                            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applySettings() }
        })
        observers.append(center.addObserver(forName: NSApplication.willTerminateNotification, object: nil,
                                            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.save() }
        })
    }

    // MARK: Control

    func enqueue(_ records: [TransferRecord]) {
        jobs.append(contentsOf: records.map(TransferJob.init))
        save()
        startNext()
    }

    /// Unfinished uploads and copies into `path` or anywhere below it on a connection.
    func uploads(at path: RemotePath, connection: UUID) -> [TransferJob] {
        jobs.filter { job in
            job.destinationConnection == connection && job.destinationPath?.hasPrefix(path) == true
        }
    }

    func cancel(_ job: TransferJob) {
        guard jobs.contains(where: { $0.id == job.id }) else { return }
        job.record.status = .cancelled
        tasks.removeValue(forKey: job.id)?.cancel()
        discardPartialState(of: job.record)
        jobs.removeAll { $0.id == job.id }
        save()
        startNext()
    }

    func retry(_ job: TransferJob) {
        guard case .failed = job.record.status else { return }
        job.record.status = .queued
        job.record.attempts = 0
        save()
        startNext()
    }

    // MARK: Settings

    private var maximumConcurrent: Int { max(1, UserDefaults.standard.integer(forKey: SettingsKey.transferConcurrency)) }
    private var retryLimit: Int { max(0, UserDefaults.standard.integer(forKey: SettingsKey.transferRetries)) }

    private func applySettings() {
        let defaults = UserDefaults.standard
        let limit = defaults.bool(forKey: SettingsKey.bandwidthLimitEnabled)
            ? defaults.integer(forKey: SettingsKey.bandwidthLimitKilobytes) * 1024
            : 0
        let limiter = limiter
        Task { await limiter.setRate(bytesPerSecond: limit) }
        startNext()
    }

    // MARK: Running

    private func startNext() {
        var running = jobs.count { $0.record.status == .running }
        for job in jobs where job.record.status == .queued && running < maximumConcurrent {
            job.record.status = .running
            running += 1
            tasks[job.id] = Task { await run(job) }
        }
    }

    private func run(_ job: TransferJob) async {
        do {
            switch job.record.kind {
            case .upload: try await runUpload(job)
            case .download: try await runDownload(job)
            case .remoteCopy: try await runRemoteCopy(job)
            }
            guard job.record.status == .running else { return }
            job.record.status = .completed
            jobs.removeAll { $0.id == job.id }
            if job.record.kind != .download {
                NotificationCenter.default.post(name: Self.uploadDidFinish, object: job)
            }
        } catch {
            // Cancelling sets the status before cancelling the task.
            guard job.record.status == .running else { return }
            let presentable = PresentableError(error)
            let transient = (StorageError.wrapping(error) as? StorageError)?.isTransient == true
            if transient && job.record.attempts < retryLimit {
                job.record.attempts += 1
                let delay = min(30, 1 << job.record.attempts)
                try? await Task.sleep(for: .seconds(delay))
                guard job.record.status == .running else { return }
                job.record.status = .queued
            } else if job.record.kind == .download {
                // Nothing in the browser shows downloads, so a failed one is reported and dropped.
                discardPartialState(of: job.record)
                jobs.removeAll { $0.id == job.id }
                downloadError = presentable
            } else {
                job.record.status = .failed(presentable.message)
            }
        }
        tasks[job.id] = nil
        save()
        startNext()
    }

    private func reporter(for job: TransferJob, finderProgress: Progress? = nil) -> TransferReporter {
        TransferReporter(
            limiter: limiter,
            onProgress: { snapshot in
                Task { @MainActor in
                    job.apply(snapshot)
                    if let finderProgress {
                        finderProgress.totalUnitCount = job.record.totalBytes ?? -1
                        finderProgress.completedUnitCount = snapshot.completedBytes
                    }
                }
            },
            onResumeToken: { [weak self] token in
                Task { @MainActor in
                    job.record.resumeToken = token
                    self?.save()
                }
            }
        )
    }

    private func provider(_ id: UUID?) throws -> any StorageProvider {
        guard let profile = store.profile(id: id) else {
            throw PresentableError(title: String(localized: "Connection Missing"),
                                   message: String(localized: "The connection of this transfer was deleted."))
        }
        return try pool.provider(for: profile)
    }

    private func options(for job: TransferJob) -> TransferOptions {
        TransferOptions(resume: job.record.completedBytes > 0 || job.record.resumeToken != nil,
                        resumeToken: job.record.resumeToken)
    }

    private func runUpload(_ job: TransferJob) async throws {
        let record = job.record
        guard let destination = record.destinationPath, let localFile = record.localFile else { return }
        let provider = try provider(record.destinationConnection)
        let access = localFile.access()
        defer { access.stop() }
        try await provider.upload(from: access.url, to: destination, options: options(for: job),
                                  reporter: reporter(for: job))
    }

    private func runDownload(_ job: TransferJob) async throws {
        let record = job.record
        guard let source = record.sourcePath, let localFile = record.localFile else { return }
        let provider = try provider(record.sourceConnection)
        let access = localFile.access()
        defer { access.stop() }
        let partialURL = Self.partialURL(for: access.url)
        let progress = Self.finderProgress(for: partialURL, job: job)
        progress.publish()
        defer { progress.unpublish() }
        try await provider.download(source, to: partialURL, options: options(for: job),
                                    reporter: reporter(for: job, finderProgress: progress))
        try Self.replaceItem(at: access.url, with: partialURL)
    }

    /// Finder shows a published file progress on the file itself, as it does for Safari downloads.
    private static func finderProgress(for url: URL, job: TransferJob) -> Progress {
        let progress = Progress(totalUnitCount: job.record.totalBytes ?? -1)
        progress.completedUnitCount = job.record.completedBytes
        progress.kind = .file
        progress.fileOperationKind = .downloading
        progress.fileURL = url
        progress.isCancellable = false
        return progress
    }

    /// Downloads into a temporary copy, then uploads it. Each phase resumes independently.
    private func runRemoteCopy(_ job: TransferJob) async throws {
        let record = job.record
        guard let source = record.sourcePath, let destination = record.destinationPath else { return }
        let sourceProvider = try provider(record.sourceConnection)
        let destinationProvider = try provider(record.destinationConnection)
        let temporaryURL = Self.temporaryURL(for: record)
        if !record.isUploadPhase {
            try await sourceProvider.download(source, to: temporaryURL, options: options(for: job),
                                              reporter: reporter(for: job))
            job.record.isUploadPhase = true
            job.record.completedBytes = 0
            job.record.resumeToken = nil
            save()
        }
        try await destinationProvider.upload(from: temporaryURL, to: destination, options: options(for: job),
                                             reporter: reporter(for: job))
        try? FileManager.default.removeItem(at: temporaryURL.deletingLastPathComponent())
    }

    private func discardPartialState(of record: TransferRecord) {
        switch record.kind {
        case .upload:
            if let token = record.resumeToken, let path = record.destinationPath,
               let provider = try? provider(record.destinationConnection) {
                Task { await provider.discardPartialUpload(to: path, resumeToken: token) }
            }
        case .download:
            if let localFile = record.localFile {
                let access = localFile.access()
                try? FileManager.default.removeItem(at: Self.partialURL(for: access.url))
                access.stop()
            }
        case .remoteCopy:
            try? FileManager.default.removeItem(at: Self.temporaryURL(for: record).deletingLastPathComponent())
            if record.isUploadPhase, let token = record.resumeToken, let path = record.destinationPath,
               let provider = try? provider(record.destinationConnection) {
                Task { await provider.discardPartialUpload(to: path, resumeToken: token) }
            }
        }
    }

    private static func partialURL(for url: URL) -> URL {
        url.deletingLastPathComponent().appending(path: url.lastPathComponent + ".ferrypart")
    }

    private static func temporaryURL(for record: TransferRecord) -> URL {
        AppDirectories.caches.appending(path: "Transfers/\(record.id.uuidString)/\(record.name)")
    }

    private static func replaceItem(at url: URL, with partialURL: URL) throws {
        let manager = FileManager.default
        if manager.fileExists(atPath: url.path) {
            try manager.removeItem(at: url)
        }
        try manager.moveItem(at: partialURL, to: url)
    }

    // MARK: Persistence

    /// Restores unfinished jobs; failed ones wait for Retry.
    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        do {
            let records = try JSONDecoder().decode([TransferRecord].self, from: data)
            jobs = records.filter(\.status.isUnfinished).map { record in
                var record = record
                if case .failed = record.status {} else {
                    record.status = .queued
                }
                return TransferJob(record: record)
            }
        } catch {
            NSLog("Ferry: restoring transfers failed: \(error.localizedDescription)")
            jobs = []
        }
    }

    /// Saves unfinished jobs.
    func save() {
        let records = jobs.map(\.record).filter(\.status.isUnfinished)
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try JSONEncoder().encode(records).write(to: fileURL, options: .atomic)
        } catch {
            NSLog("Ferry: saving transfers failed: \(error.localizedDescription)")
        }
    }
}
