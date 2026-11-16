# AI Agent Guidelines (`nikrun/cli`)

**Nikrun** is a zero-config, user-scope toolchain and developer ecosystem for **Object Pascal / Free Pascal** (`3.2.2`, `3.2.4`, and `3.3.1`), organized across three repositories under `https://github.com/nikrun`:

1. **[`nikrun/cli`](https://github.com/nikrun/cli)** *(this repository)* — Standalone `nik` CLI (`src/nik.*.pas`) and standalone `nikrun-lsp-protocol` (`lsp-protocol/`).
2. **[`nikrun/sdk`](https://github.com/nikrun/sdk)** — Portable Free Pascal SDK build pipeline, `versions.json`, and GitHub Releases (`latest`).
3. **[`nikrun/vscode`](https://github.com/nikrun/vscode)** — Official `vscode-nikrun` Visual Studio Code extension.

---

## Essential Context & Documentation

Before designing new CLI subcommands, flags, manifests, or architectural changes, consult:

1. **[`README.md`](./README.md)** — Ecosystem architecture, `src/nik.*.pas` unit responsibilities, `nik.yaml` overview, and supported environment variables.
2. **[`lsp-protocol/README.md`](./lsp-protocol/README.md)** — Zero-dependency LSP 3.17 & JSON-RPC 2.0 library (`lsp-protocol/src/nikrun.lsp.*.pas`).
3. *(Local multi-repo workspace)* **`../docs/design-radar.md`** & **`../docs/specs/nik-yaml.md`** when present alongside this checkout.

---

## Core Engineering Rules

- **Terminology & Typography:**
  - **Nikrun** (capitalized prose, no backticks) refers to the overall project and ecosystem (portable FPC SDKs, website, documentation, CLI tool, LSP/DAP, VS Code extension, GitHub Action, etc.).
  - **`nik`** (lowercase in inline code backticks in Markdown; `nik` in terminal output) refers specifically to the CLI tool binary and its commands.
  - Keep technical identifiers (`~/.nikrun`, `--nikrun-home`, `NIKRUN_HOME`, `nikrun-fpc-sdk-*`, `vscode-nikrun`, `setup-nikrun`, `nikrun.dev`, `nik.yaml`) in their exact lowercase technical form.
- **Pure Object Pascal & Compiler Compatibility:** Write clean `{$mode objfpc}{$H+}` code in `src/` and `lsp-protocol/src/` that compiles cleanly on **both** Free Pascal `3.2.2` and `3.3.1` with zero external runtime library dependencies (`libssl`, `libc` wrappers, etc. must not be required at runtime unless standard on the target OS). Keep `lsp-protocol/src/` strictly free of `nik.*` CLI unit imports.
- **Defensive `case` Statements:** Never write `case ... of` statements without an `else` branch. Always include an explicit `else` branch (raising an exception such as `ENikError` when an unexpected enum/value is encountered).
- **Cross-Platform Parity:** Support `win64`, `linux`, and `darwin` (`x86_64` and `aarch64`). Isolate OS-specific APIs cleanly behind `{$IFDEF WINDOWS}` / `{$IFDEF UNIX}` boundaries.
- **Agent & CI Friendly CLI:**
  - Provide `--json` output on commands that inspect state, build projects, or run tests.
  - Respect `NO_COLOR` / `--no-color`, non-TTY streams (`IsInteractiveOutput`), and `CI` environments—never block automated runs on interactive prompts.
  - Keep global state inside `~/.nikrun` (`--nikrun-home` / `NIKRUN_HOME`) and project build caches strictly checkout-local (safe for parallel Git worktrees and concurrent agents).

---

## Build & Verification Commands

Run commands from the repository root (`pwsh` / Windows PowerShell):

```powershell
# Build the nik CLI (debug profile with DWARF info & runtime checks -> bin/nik[.exe])
.\build.ps1

# Build optimized release binary
.\build.ps1 -Profile release

# Run the automated CLI & LSP end-to-end test suite
.\test.ps1

# CI flow: provision newest Nikrun FPC SDK from nikrun/sdk, then build & stage release artifact in dist/cli/
.\prepare.ps1
.\build.ps1 -Profile release -Clean -StageDist
```
