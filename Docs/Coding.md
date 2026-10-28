# Coding

## Conventions
- Idiomatic Swift and SwiftUI, Swift API Design Guidelines, complete English names.
- One primary type per file; small tightly related helpers may share it.
- Native SwiftUI state: `@State`, `@AppStorage`, and `@Observable` classes for state shared across views
  (`ConnectionStore`, `ConnectionPool`, `TransferQueue`, `RemoteClipboard`, `BrowserWindowModel`,
  `BrowserTab`), injected with `.environment(_:)`. No view models or DI containers beyond these.
- No force unwraps or swallowed errors. User-visible failures become a `PresentableError`; best-effort
  cleanup (closing handles, deleting temp files, aborting multipart uploads) may use `try?`.
- Comments explain intent or constraints only.

## Concurrency
- App target: Swift 5 mode, `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, approachable concurrency. UI
  state lives on the main actor; types crossing to other isolation domains are declared `nonisolated`
  (for example `RemoteDragPayload`).
- `FerryStorage`: Swift 6 language mode with strict concurrency. Providers are `final class … Sendable`
  with immutable state; mutable shared state uses `Mutex` (Synchronization) or actors (`BandwidthLimiter`).
- Long operations honor task cancellation; `URLError.cancelled` maps to `CancellationError`.
- Providers map protocol failures onto `StorageError` (`StorageError.wrapping` for Foundation errors).

## Adding a protocol
1. Add a target to [`Packages/FerryStorage/Package.swift`](../Packages/FerryStorage/Package.swift) depending
   on `StorageCore`, and add it to the `FerryStorage` product.
2. Implement `StorageProvider`, declare accurate `StorageCapabilities`, report progress and resume tokens
   through `TransferReporter`, and call `reporter.throttle(_:)` before each chunk.
3. Create the provider in `ConnectionPool.makeProvider` from the profile's settings and Keychain secrets.
4. Add unit tests under `Packages/FerryStorage/Tests/<Module>Tests`.

## Build and test
- App: open `Ferry.xcodeproj` and build the `Ferry` scheme. Xcode resolves the local package and its
  remote dependencies (`swift-nio`, `swift-nio-ssh`) on the first build.
- Package tests: `swift test` in `Packages/FerryStorage`, or the `FerryStorage-Package` scheme in Xcode.
- The tests use Swift Testing. S3 signing is checked against the AWS Signature Version 4 examples.
