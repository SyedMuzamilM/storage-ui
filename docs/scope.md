# Current scope

Storage focuses on the main S3-compatible file workflows: browsing, uploads, downloads, previews, signed links, folder creation, copy/move, rename, and recursive deletion. The interface uses separate Zircon UI views, and application behavior is implemented in Zig.

## Current limits

- One active connection, with optional macOS Keychain persistence.
- macOS native UI, using the sibling zigpui workspace.
- Regular-file uploads in a serial queue. Finder directory uploads and multipart/resumable transfers are not implemented.
- Upload byte progress, cancellation, and retry. Downloads show their operation status and completion, without byte progress or cancellation.
- Text and image preview reads up to 1 MiB; large files may need downloading.
- Rename applies to individual files. Copy/cut/paste and deletion support selections and folders.
- Destination checks protect existing copy names. Providers that ignore conditional CopyObject headers can still race another writer after the preflight check.
- Expiring GET and PUT links. A PUT link allows writing its specified object key until expiry.
- Up to 100,000 listed entries, with continuation-token pagination.

Version administration, bucket settings, sync jobs, encryption controls, upload rules, and incomplete multipart-upload management are outside this iteration.

## Verification coverage

Behavior tests exercise demo navigation and UI actions, selection, drops, signing, downloads, overwrite protection, folder operations, safe paths, and password masking.

The local S3 fixture independently checks request signatures, Unicode keys, session tokens, pagination, upload progress, copy/move, ambiguous-copy handling, and recovery when a refresh fails after saving.

The native journey verifies the AppKit drop adapter, the multi-file queue, command palette, and signed-link dialog. The opt-in live provider check uses the real controller and transfer jobs inside an isolated temporary prefix.

## Verified against Cloudflare R2

On 2026-11-08, the live check passed against the configured `assets` bucket. It verified two queued uploads including a Unicode key and a 256 KiB binary, upload progress counters, exact download contents, remote/local collision protection, text preview, signed GET and PUT requests, copy, rename, nested downloads, and recursive deletion. All test objects were removed afterward.

The local suite also checks canonical header ordering, including the copy-source conditional header pair that older curl signing implementations sort incorrectly. Request and URL signing run in Zig; curl supplies HTTP transport.
