# SFTP

Source: [`Packages/FerryStorage/Sources/SFTPStorage/`](../../Packages/FerryStorage/Sources/SFTPStorage/).

## Settings
Host, Port (22), Username, Authentication (Password, or Private Key with optional Passphrase), Initial
Path. The private key file is read once when chosen and stored in the Keychain with the passphrase, so
no file access is needed later. An empty Initial Path opens the login directory (`REALPATH .`).

## Authentication and host keys
- Password authentication, or public-key authentication with Ed25519 or ECDSA (P-256, P-384, P-521) keys.
- Key formats: OpenSSH (`BEGIN OPENSSH PRIVATE KEY`, unencrypted or encrypted with bcrypt-pbkdf and
  AES-128/192/256 CTR or AES-128/256 CBC), PKCS#8, and SEC1 PEM EC keys. Encrypted PEM keys are rejected.
- Not supported (swift-nio-ssh limitations): RSA keys, keyboard-interactive authentication, and servers
  offering only RSA host keys.
- Host keys: an unknown key asks "Trust “host”?" with its SHA-256 fingerprint; trusted keys are saved in
  `known_hosts.json`; a changed key fails with "Host Key Changed".

## Behavior
- One SSH connection per connection profile, shared by browsing and transfers, reconnected on the next
  operation after it drops. Credential errors and host-key decisions are reported specifically.
- **Listing**: OPENDIR/READDIR, streamed per batch. Owner and group come from the server's `ls -l` line;
  symbolic links to directories are listed as directories.
- **Transfers**: 32 KiB requests, 32 in flight. Downloads resume from the local partial file when the
  remote size and modification time are unchanged. Uploads resume from the remote size minus one
  pipeline window (1 MiB), the last point known to be contiguous.
- **Move / rename**: `posix-rename@openssh.com` when available (replaces the destination), else RENAME.
- **Copy**: SFTP v3 has no server-side copy; data streams through Ferry within the session, recursively
  for folders, keeping permissions.
- **Delete**: recursive for folders; links are removed, not followed.
- **Permissions**: chmod through SETSTAT, from the Permissions… menu item.
- **URL**: `sftp://user@host[:port]/path`.

## Tests
[`SFTPStorageTests.swift`](../../Packages/FerryStorage/Tests/SFTPStorageTests/SFTPStorageTests.swift):
private keys generated with `ssh-keygen` (plain and passphrase-protected) must yield the same public key
as `ssh-keygen`; wrong and missing passphrases; RSA rejection; attribute encoding; packet framing with
split and out-of-order responses on an embedded channel; fingerprint format.
Not verified yet: connections to a live SSH server.
