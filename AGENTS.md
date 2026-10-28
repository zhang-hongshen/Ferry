# Ferry

Native macOS client for remote file and object storage (S3, SFTP, FTP/FTPS, WebDAV, SMB) behind one
unified storage interface. SwiftUI, macOS 15.0+, sandboxed.

## Repository Index
- `Ferry.xcodeproj/`: app project; the `Ferry` target uses a file-system-synchronized `Ferry/` group.
- `Ferry/`: app source — `App/`, `Connections/`, `Browser/`, `Sidebar/`, `Inspector/`, `Transfers/`,
  `Settings/`, `Support/`, `Localizable.xcstrings`.
- `Packages/FerryStorage/`: local Swift package with the unified protocol layer (`StorageCore`) and one
  module per protocol (`S3Storage`, `SFTPStorage`, `WebDAVStorage`, …). SFTP depends on `swift-nio-ssh`. Tests live in `Packages/FerryStorage/Tests/`.
- `Design/AppIcon/`: Blender 3D ferry model for the app icon. `build_icon_model.py` builds `FerryIcon.blend` and
  renders the `Ferry/AppIcon.icon` layers (`sea.png`, `ferry.png`) plus `FerryModel.png`
  (`blender -b -P Design/AppIcon/build_icon_model.py -- --render`).
- `Docs/`: shared documentation; start at [`Docs/AGENTS.md`](Docs/AGENTS.md).

## Rules
- Follow the project configuration: macOS 15.0 deployment target, App Sandbox, Swift 5 language mode with
  `MainActor` default isolation in the app; Swift 6 language mode in `FerryStorage`.
- The UI talks only to `StorageProvider`. Protocol-specific behavior stays inside its module; the UI
  gates optional features on `StorageCapabilities`, never on the protocol kind.
- Secrets (passwords, secret keys, private keys, passphrases) go to the Keychain only, never to JSON or exports.
- Prefer simple implementations and native accessible controls. Avoid force unwraps and swallowed errors.
- Add new user-facing strings to `Ferry/Localizable.xcstrings` with an `zh-Hans` translation.
- Update relevant tests and docs with behavior changes. Report only checks actually performed.

## UI Principles
- Let layout, grouping, native controls, icons, and visible state explain the UI. Do not explain the UI with prose.
- Do not add secondary labels, subtitles, captions, descriptions, helper text, or tooltips that restate a title or describe an obvious control.
- Do not add section headers or footers that repeat the only row's label or just introduce a single control.
- Fix unclear UI by renaming or restructuring, not by adding explanatory text.
- Add visible explanatory text only for non-obvious consequences, constraints, or errors; keep it to one short sentence.
- Keep accessibility labels, values, and hints; they are not visible text and are still required.
- Before finishing a UI change, delete every visible string whose removal loses no information.
