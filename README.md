# Ferry

Native macOS file transfer client for S3, SFTP and WebDAV, with a unified browser and transfer queue.

## Features

- Connect to S3-compatible object storage, SFTP servers and WebDAV endpoints.
- Browse remote folders and buckets, inspect items, and manage files in one interface.
- Upload and download files through a transfer queue.
- Use S3 metadata, bucket management and presigned download links where supported.
- Store passwords, private keys and secret keys in the macOS Keychain.
- Use an English or Simplified Chinese interface with appearance settings.

## Requirements

- macOS 15 or later.
- Xcode 27 or later to build from source.

## Installation

Download the DMG from [GitHub Releases](https://github.com/zhang-hongshen/Ferry/releases), open it, and move Ferry to Applications. For an ad-hoc signed build, macOS may require approval in System Settings → Privacy & Security.

## Getting started

1. Create an S3, SFTP or WebDAV connection and enter its credentials.
2. Browse the remote location and select files or folders.
3. Start transfers and follow their progress in the transfer queue.

## Protocol support

S3, SFTP and WebDAV are implemented. FTP/FTPS and SMB connection types are reserved and are not available yet.

## Build from source

Open `Ferry.xcodeproj` in Xcode, select the `Ferry` scheme and My Mac, resolve its Swift packages, then build and run.

## Releases

Pushing an annotated version tag triggers the release workflow. Release titles contain only the version number; release notes contain only the numbered feature list from the tag body.
