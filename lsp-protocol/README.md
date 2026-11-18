# nikrun-lsp-protocol

> **Standalone, Zero-Dependency Language Server Protocol (LSP 3.17) & JSON-RPC 2.0 Library for Free Pascal**  
> Maintained inside [`https://github.com/nikrun/cli`](https://github.com/nikrun/cli) (`lsp-protocol/`)

`nikrun-lsp-protocol` provides a clean-room implementation of the **Language Server Protocol (LSP 3.17)** and **JSON-RPC 2.0** in pure Object Pascal (`{$mode objfpc}{$H+}`), licensed under the GNU GPLv3+ (`GPL-3.0-or-later`).

It is completely independent of Lazarus/`CodeTools` and independent of the `nik` CLI—relying exclusively on standard Free Pascal RTL/FCL units (`SysUtils`, `Classes`, `fpjson`, `jsonparser`, `ssockets`) and compiling cleanly on both **Free Pascal `3.2.2` and `3.3.1`** across `win64`, `linux`, and `darwin` (`x86_64` & `aarch64`).

---

## Key Features

- **Zero External Runtime Dependencies:** Compiles into a single native executable with no external `.dll`, `.so`, or `.dylib` requirements.
- **Zero-Allocation Value Types (`advancedrecords`):** Models LSP structures, optionals (`TLspOptional<T>`), and hierarchical `DocumentSymbol` trees using managed records and direct `fpjson` codecs—avoiding RTTI bottlenecks and manual heap cleanup.
- **Binary Byte-Framed Transport (`Content-Length`):**
  - `TLspStreamTransport` for arbitrary `TStream` pairs (including deterministic in-memory unit tests)
  - `TLspStdioTransport` operating directly on raw OS handles (`StdInputHandle` / `StdOutputHandle`) while redirecting standard Pascal `Output` (`Write`/`WriteLn`) to `stderr` so accidental console output never corrupts the JSON-RPC stream
  - `TLspTcpServerTransport` (`127.0.0.1:<port>`) for attaching a live debugger to a running language server
- **UTF-16 <-> UTF-8 & Cross-Platform `file://` URI Utilities:**
  - RFC 8089 `file://` URI conversion handling Windows drive letters (`file:///c:/...`, `file:///c%3A/...`), UNC shares, POSIX paths, and percent-encoding
  - Accurate UTF-16 code-unit <-> UTF-8 byte column conversion (including 4-byte supplementary plane surrogate pairs)
- **Built-In Document Store (`TLspDocumentStore`):** Tracks open buffers across `didOpen`, `didChange` (*Full* and multi-range *Incremental* sync), `didSave`, and `didClose`, with fast binary-searched line indexes and identifier extraction.
- **Turnkey `TLspServer` Base Class:** Implements the LSP lifecycle state machine (`initialize`, `initialized`, `shutdown`, `exit`, `$/cancelRequest`, `-32002 ServerNotInitialized` enforcement) and exposes typed virtual methods for language features.

---

## Unit Overview (`src/`)

| Unit | Responsibility |
| :--- | :--- |
| `nikrun.lsp.types.pas` | LSP 3.17 value types, `TLspOptional<T>`, error codes, capabilities, and `fpjson` codecs |
| `nikrun.lsp.uri.pas` | Cross-platform `file://` URI <-> native file path conversion and normalization |
| `nikrun.lsp.utf16.pas` | UTF-16 code-unit <-> UTF-8 byte index conversion on source lines |
| `nikrun.lsp.transport.pas` | Binary `Content-Length` framing over `TStream`, guarded `stdio`, and loopback TCP sockets |
| `nikrun.lsp.jsonrpc.pas` | JSON-RPC 2.0 request/notification/response parser, envelope builders, and cancellation tracker |
| `nikrun.lsp.documents.pas` | Stateful in-memory text document store supporting Full & Incremental UTF-16 edits |
| `nikrun.lsp.server.pas` | Abstract `TLspServer` base class, lifecycle state machine, and server->client notifications |

---

## Building & Running Tests

With PowerShell (`pwsh` on Windows/Linux/macOS, using either an installed Nikrun FPC SDK in `~/.nikrun` or `fpc` on `PATH`):

```powershell
.\test.ps1
```

Or directly with Free Pascal:

```bash
fpc -Mobjfpc -Sh -Fusrc -FEbin tests/lsp_protocol_tests.pas
./bin/lsp_protocol_tests
```

---

## License

Copyright (c) 2026 The Nikrun Contributors.

Licensed under the **GNU General Public License v3.0 or later** (`GPL-3.0-or-later`) — see [LICENSE](./LICENSE).
