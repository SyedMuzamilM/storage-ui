# Storage

A native macOS S3 browser written in Zig with Zircon UI. It uses the local `../zigpui` workspace for UI, text editing, and rendering.

## Build and run

Use `./tools/zig`, which selects the Zig 0.17.1 toolchain and standard-library overlay from the sibling workspace.

```sh
./tools/zig build
open zig-out/Storage.app
```

The build installs `zig-out/Storage.app` and `zig-out/bin/storage-ui`. To explore without credentials:

```sh
./tools/zig build run -Ddemo=true
```

## Connect an account

Storage reads `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, optional `AWS_SESSION_TOKEN`, `AWS_REGION`, `S3_ENDPOINT`, and `S3_BUCKET`. Set `S3_AUTOCONNECT=1` to connect on launch. Cloudflare R2 uses region `auto`. A bucket-scoped R2 token needs its bucket name because it may not allow account-wide bucket listing.

The account can also be supplied as one JSON line on stdin with `--account-stdin`. Its fields are `access_key_id`, `secret_access_key`, `endpoint`, `region`, `bucket`, and optional `session_token`. Add `--remember-account` to store it in the macOS Keychain. Use the bundled executable for this so Keychain trusts the executable you will launch. A rebuilt development executable may need the account saved again to refresh its Keychain trust. Normal launches then load that account and connect automatically. A complete, nonempty environment credential pair takes precedence. Partial credentials do not hide the saved account. Keep credentials out of command arguments and repository files.

## Core workflows

- Browse folders, filter, sort, switch to a flat listing, and select multiple objects.
- Upload multiple files using **Upload** or by dropping files onto the current folder or a folder row. The upload queue shows byte progress and speed, with cancellation and retry.
- Download files, selections, and folders. Folder downloads preserve relative paths. Existing remote upload names and local download files are protected.
- Copy, cut, paste, rename files, and recursively delete selected folders after confirmation.
- Preview text, hexadecimal bytes, and supported images. Previews read at most 1 MiB.
- Generate expiring signed GET and PUT links and copy them to the clipboard.
- Search commands with **Cmd-K**. **Cmd-U/D/R/C/X/V/A** handles upload, download, refresh, copy, cut, paste, and selection.

Downloads publish the completed temporary file only after checking its size. Uploads stream through libcurl. Other S3 requests use the system curl executable with credentials supplied through its environment. Signing, storage operations, application state, and native platform bindings are implemented in Zig.

See [scope](docs/scope.md) for current limits. The UI takes inspiration from [Pail](https://github.com/DejavuMoe/Pail); this project does not bundle Pail's Go engine.

## Source layout

| Directory | Responsibility |
| --- | --- |
| `src/app` | Browser state, commands, input, and job completion |
| `src/models` | Selection, clipboard, preview, and transfer state |
| `src/storage` | S3 requests, XML, SigV4 links, and background jobs |
| `src/transfers` | Upload streaming, download validation, and local file publication |
| `src/platform` | Keychain and libcurl ABI bindings |
| `src/views` | Separate native views and shared controls |
| `src/testing` | UI driver and opt-in live provider checks |

Use `zig fmt`, multiline initializers for larger structures, and a single blank line between logical steps. Keep adjacent fields and related statements together.

The sibling Zircon UI dependency includes native multi-file selection, Finder drops, click modifiers, and masked text inputs. Those APIs are available from zigpui commit `a6a897a` onward.

## Verification

```sh
./tools/zig fmt --check build.zig build.zig.zon src
./tools/zig build test
python3 tools/test_s3.py
./tools/zig build test-native
```

The Python fixture independently verifies SigV4 requests and tests failures as well as successful operations. The native journey exercises AppKit file drops and captures palette and sharing views under `/tmp/storage-ui-*.png`.

Live provider verification is opt-in:

```sh
zig-out/Storage.app/Contents/MacOS/Storage --test-s3
```

It requires a configured account with read/write permissions and an explicit bucket. It creates a uniquely named `storage-ui-test-<timestamp>/` prefix, checks uploads, collision protection, downloads, preview, signed GET/PUT links, copy, rename, folder downloads, and recursive deletion, then removes its test objects. If cleanup fails, it prints the exact test prefix for manual removal. Existing objects outside that prefix are never changed.

`--inspect` lists the configured bucket's root entries. `--verify-url` performs a one-byte range read using a signed GET URL.
