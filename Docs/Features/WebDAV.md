# WebDAV

Source: [`Packages/FerryStorage/Sources/WebDAVStorage/`](../../Packages/FerryStorage/Sources/WebDAVStorage/).

## Settings
URL (an `http://` or `https://` collection, for example `https://cloud.example.com/remote.php/dav/files/alice/`),
Username, Password (Keychain), Initial Path (relative to the URL). The URL's collection is the root `/`.
`http://` URLs work only for local network hosts; see [Architecture](../Architecture.md#plain-http).

## Authentication
- Over HTTPS, Basic credentials are sent with every request, so streamed uploads never need a second body.
- Otherwise URLSession answers Basic, Digest, and NTLM challenges once; a repeated challenge or a `401` is
  reported as "Authentication Failed".

## Behavior
- **Listing**: `PROPFIND Depth: 1` on the collection URL (always with a trailing "/"), requesting
  resourcetype, size, modification date, ETag, and content type. `propstat` blocks that are not `200`
  are ignored. `href`s may be absolute URLs or paths; entries outside the base collection are dropped.
  Recursive listings walk `Depth: 1` level by level, because many servers disable `Depth: infinity`.
- **Folders**: `MKCOL`; `405` maps to "Already Exists" and `409` to the missing parent.
- **Copy / move / rename**: server-side `COPY` (`Depth: infinity`) and `MOVE`, both with `Overwrite: T`.
  A `207` reply (partial failure) is reported as an error, as is a `207` from `DELETE`.
- **Upload**: `PUT` with `Content-Length`, the body streamed through a bound stream pair in 64 KiB chunks,
  so progress and the bandwidth limit apply while sending. If the server requests the body again (a Digest
  challenge over HTTP), the upload is retried from the file once, without bandwidth limiting. Uploads are
  not resumable: WebDAV has no standard partial PUT.
- **Download**: 8 MiB `Range` requests streamed straight into the destination file. The ETag (or size and
  date) is the resume token. A server that ignores `Range` and answers `200` has the whole file written in
  one pass.
- **URL**: the resource's HTTP URL, without credentials.
- Errors: `403` Permission Denied, `404`/`410` Not Found, `423` Locked, `507` no storage, `5xx` retried.

## Tests
[`WebDAVStorageTests.swift`](../../Packages/FerryStorage/Tests/WebDAVStorageTests/WebDAVStorageTests.swift)
runs the provider against an in-memory server ([`MockWebDAVServer.swift`](../../Packages/FerryStorage/Tests/WebDAVStorageTests/MockWebDAVServer.swift))
installed as a `URLProtocol`: create/list/copy/move/delete, a 300 KB streamed upload with progress, a
resumed ranged download, a server that ignores `Range`, wrong credentials, a missing parent, plus
multistatus parsing (namespaces, failed propstats, absolute hrefs) and URL encoding.
Not verified yet: real servers (Nextcloud, Apache `mod_dav`, Synology), Digest authentication, and the
upload fallback.
