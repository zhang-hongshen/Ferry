# Architecture

## Modules

```text
Ferry (app target, SwiftUI)
 ├─ App/          FerryApp, MainWindow, menu commands
 ├─ Connections/  ConnectionProfile, ConnectionStore, KeychainStore, ConnectionPool, editor
 ├─ Sidebar/      grouped connections, favorites, S3 buckets
 ├─ Browser/      BrowserWindowModel (tabs), BrowserTab (listing + history), icon, list, and column views, path bar
 ├─ Inspector/    attributes, thumbnails, S3 metadata editor
 ├─ Transfers/    TransferQueue, TransferJob, FileOperations, conflict prompts
 ├─ Settings/     General (appearance, language) and Transfers settings
 └─ Support/      PresentableError, AppDirectories, small helpers
        │ imports
        ▼
Packages/FerryStorage (local Swift package, product "FerryStorage")
 ├─ StorageCore   StorageProvider protocol, RemotePath, RemoteItem, RemoteMetadata,
 │                StorageCapabilities, StorageError, TransferReporter, BandwidthLimiter
 ├─ S3Storage     S3Provider (SigV4 signer, REST client, XML parsing, multipart, presign)
 ├─ SFTPStorage   SFTPProvider (SFTP v3 client on swift-nio-ssh, OpenSSH key parsing)
 └─ WebDAVStorage WebDAVProvider (URLSession: PROPFIND, MKCOL, COPY/MOVE, streamed PUT, ranged GET)
```

Dependencies point one way: app → protocol modules → `StorageCore`. Protocol modules never import each
other or the app. Only [`ConnectionPool.makeProvider`](../Ferry/Connections/ConnectionPool.swift) knows the
concrete provider types; everything else uses `any StorageProvider`.

### Unified protocol layer

[`StorageProvider`](../Packages/FerryStorage/Sources/StorageCore/StorageProvider.swift) defines listing
(streamed in pages), item lookup, upload, download, delete (recursive), move, copy, and directory
creation. Optional operations (chmod, presigned URLs, metadata, buckets, discarding partial uploads) have
default implementations that throw `StorageError.unsupported`. Each provider declares
[`StorageCapabilities`](../Packages/FerryStorage/Sources/StorageCore/StorageCapabilities.swift); the UI shows
columns, menu items, and inspector sections from these flags (for example the Permissions/Owner columns
from `.posixAttributes`, presigned links from `.presignedURLs`).

Every path is an absolute [`RemotePath`](../Packages/FerryStorage/Sources/StorageCore/RemotePath.swift).
S3 maps it as `/bucket/key/parts`: the root lists buckets, and keys are split on "/" (ListObjectsV2
with `delimiter=/`), so S3 browses like a file system.

### Protocol modules

| Protocol | Module | Status | Approach |
| --- | --- | --- | --- |
| S3 / S3-compatible | `S3Storage` | Implemented | URLSession + CryptoKit SigV4, no dependencies |
| SFTP | `SFTPStorage` | Implemented | Apple's `swift-nio-ssh` for SSH; Ferry's own SFTP v3 client and private-key parser |
| FTP / FTPS | `FTPStorage` | Planned | Network.framework control and data connections, explicit/implicit TLS, passive/active mode (`REST` for resume) |
| WebDAV | `WebDAVStorage` | Implemented | URLSession: `PROPFIND`, `MKCOL`, `MOVE`, `COPY`, streamed `PUT`, ranged `GET` |
| SMB | `SMBStorage` | Planned | Native NetFS mount + FileManager; must be checked against the App Sandbox |

The connection editor already has the settings form for every protocol; connecting with an unimplemented
protocol shows "connections are not available yet".

## Data Flow

- **Browsing**: selecting a connection or bucket in the sidebar calls `BrowserWindowModel.open`, which
  asks `ConnectionPool` for the cached provider and has the current `BrowserTab` stream `list(_:)` pages
  into `items`. `visibleItems` (filtered, sorted, containers first) drives the list (`Table`) or icon
  (`LazyVGrid`) view; the mode is the `browserViewMode` preference (⌘1 / ⌘2). In the list, expanding a
  folder lists it into `childItems` and shows it in place; double-clicking navigates into it. Refresh
  reloads expanded folders; changing location collapses them. History is a
  back/forward stack per tab. A network failure or dropped connection triggers one
  `ConnectionPool.reconnect` and reload before an error is shown.
- **Commands**: menu commands reach the focused window through `FocusedValues.browserWindow` and set
  `BrowserTab.pendingAction`; `BrowserView` performs the action with its own sheets and panels.
- **File operations**: [`FileOperations`](../Ferry/Transfers/FileOperations.swift) resolves name
  conflicts (replace / skip / keep both / apply to all, via `ConflictResolver`), creates remote or local
  directories, and enqueues one `TransferRecord` per file.
- **Finder-style editing**: Return, Rename, New Folder (which creates "untitled folder"), and clicking the
  name of the only selected item (after the double-click interval, via `nameClickMonitor`, which observes
  mouse-ups without taking them from the views) edit the name in place through `BrowserTab.renamingPath`
  and `InlineNameField`; committing moves the item.
- **Column view**: `FileColumnView` shows one column per folder from `BrowserTab.topPath` to the current
  directory. Selecting a single folder navigates into it; the columns above keep their listings in
  `BrowserTab.columnItems`, pruned to the current path's ancestors. Delete is
  immediate and permanent, folders with everything inside. Opening a file
  ([`RemoteFileEditor`](../Ferry/Transfers/RemoteFileEditor.swift)) downloads it to `Caches/Ferry/Editing`,
  opens it in its default app, and enqueues an upload to the same location each time the copy is saved. Paste and drag between tabs/windows use server-
  side copy/move within one connection, and download-then-upload `remoteCopy` jobs across connections.
- **Transfers**: [`TransferQueue`](../Ferry/Transfers/TransferQueue.swift) runs jobs up to the configured
  concurrency. Providers report progress through `TransferReporter`, which also applies the shared
  `BandwidthLimiter` and records resume tokens. Transient errors retry with exponential backoff up to the
  configured count. Finished jobs leave the queue; there is no transfer window. Uploads and cross-connection
  copies appear in the browser at their destination (`BrowserTab.withUploads`): files not listed yet get
  dimmed placeholder rows, files show a progress ring, folders receiving uploads a spinner, and failures a
  warning with Retry Upload / Cancel Upload in the context menu. A finished upload is merged into the
  listing without a reload (`TransferQueue.uploadDidFinish`). Downloads publish a file `Progress` on the
  `.ferrypart` file so Finder shows it; a failed download is dropped and shown as an alert. Cancel discards
  partial state (S3: AbortMultipartUpload).
- **S3 transfers**: files under 16 MiB use one PUT; larger files use multipart upload (≥ 8 MiB parts, 4
  concurrent, ListParts on resume). Downloads use 8 MiB ranged GETs with `If-Match` on the ETag, appending
  to a `.ferrypart` file that replaces the destination on completion.

## Persistence

- Connections: `connections.json` in the app's Application Support folder (sandbox container). Each
  profile stores only its active protocol's settings. Import/export uses the same format without secrets.
- Secrets: Keychain generic passwords, service `com.zhanghongshen.Ferry.connection`, account
  `<connection UUID>/<field>`.
- Transfers: unfinished jobs in `transfers.json`, saved on status changes and at quit; resumed on launch
  (failed uploads wait for Retry).
  Local files are referenced by a security-scoped bookmark of the user-chosen root plus a relative path.
- SSH host keys: `known_hosts.json` in Application Support, keyed by `host:port`.
- Caches: previews, Quick Look copies, files open for editing, and cross-connection temporary files under
  `Caches/Ferry`.
- Preferences: `UserDefaults` (`SettingsKey`).

## Decisions

- **Local package per protocol layer** instead of app folders, so protocol modules build and test
  independently, compile in Swift 6 mode, and third-party dependencies (SSH) stay isolated in one module.
- **swift-nio-ssh for SFTP**: macOS has no public SSH API. swift-nio-ssh is Apple-maintained and pure
  Swift, but it only implements SSH transport, so Ferry implements SFTP v3 and OpenSSH key decryption
  (bcrypt-pbkdf + AES) itself. It cannot sign with RSA keys and has no keyboard-interactive auth.
- **Host keys are trusted on first use**: an unknown key is shown with its SHA-256 fingerprint for
  confirmation; a changed key is refused. Trusted keys live in `known_hosts.json`.
- **No S3 SDK**: SigV4 is small and verified against AWS test vectors; avoiding the AWS SDK keeps the app
  dependency-free.
- **Chunked downloads** instead of URLSession download tasks, so progress, bandwidth limiting, and resume
  work the same way for every provider.
- **In-window tabs** instead of native window tabs, so each tab keeps its own connection and history and
  menu commands can address the current tab.
- **App Sandbox stays on.** Outgoing network, user-selected read/write files, and the Downloads folder are
  enabled. FTP active mode (incoming connections) and SMB mounting still need sandbox review.
- <a id="plain-http"></a>**Plain HTTP only on the local network.** App Transport Security blocks
  `http://` in URLSession on every macOS version; [`Ferry/Info.plist`](../Ferry/Info.plist) sets only
  `NSAllowsLocalNetworking`, so local servers (MinIO, WebDAV) work while other hosts need HTTPS. A blocked
  request is reported as a configuration error asking for HTTPS.
- **Cross-connection cut** copies only; the source is not deleted.
- Not implemented yet: FTP/SMB providers, sync (local ↔ remote diff), remote editing with
  upload-on-save, dragging files out to Finder.
