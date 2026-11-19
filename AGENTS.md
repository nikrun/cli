# AI Agent Guidelines (`nikrun/cli`)

**Nikrun** is a zero-config, user-scope toolchain and developer ecosystem for **Free Pascal & Object Pascal** (`3.2.2`, `3.2.4`, and `3.3.1`), organized across seven repositories under `https://github.com/nikrun`:

1. **[`nikrun/cli`](https://github.com/nikrun/cli)** *(this repository)* — Standalone `nik` CLI (`src/nik.*.pas`) and standalone `nikrun-lsp-protocol` (`lsp-protocol/`).
2. **[`nikrun/sdk`](https://github.com/nikrun/sdk)** — Portable Free Pascal SDK build pipeline, `versions.json`, and GitHub Releases (`latest`).
3. **[`nikrun/vscode`](https://github.com/nikrun/vscode)** — Official **Nikrun for VS Code** (`nikrun.vscode`) extension.
4. **[`nikrun/github-setup-nik`](https://github.com/nikrun/github-setup-nik)** — Official GitHub Action installing `nik` in CI workflows.
5. **[`nikrun/web`](https://github.com/nikrun/web)** — Official `nikrun.dev` website, VitePress documentation, and CLI installer endpoints.
6. **[`nikrun/brand`](https://github.com/nikrun/brand)** — Canonical vector marks, icons, favicons, and social preview cards.
7. **[`nikrun/build-lib`](https://github.com/nikrun/build-lib)** — Shared PowerShell build, packaging, SBOM, and release automation library.

---

## Essential Context & Documentation

Before designing new CLI subcommands, flags, manifests, documentation, or architectural changes, consult:

1. **[`README.md`](./README.md)** — Ecosystem architecture, `src/nik.*.pas` unit responsibilities, `nik.yaml` overview, and supported environment variables.
2. **[`lsp-protocol/README.md`](./lsp-protocol/README.md)** — Zero-dependency LSP 3.17 & JSON-RPC 2.0 library (`lsp-protocol/src/nikrun.lsp.*.pas`).
3. *(Local multi-repo workspace)* **`../internal-notes/messaging.md`**, **`../internal-notes/design-radar.md`**, & **`../internal-notes/specs/nik-yaml.md`** when present alongside this checkout.

---

## Core Engineering Rules

- **Terminology & Typography:**
  - **Nikrun** (capitalized prose, no backticks) refers to the overall project and ecosystem (portable FPC SDKs, website, documentation, CLI tool, LSP/DAP, VS Code extension, GitHub Action, etc.).
  - **`nik`** (lowercase in inline code backticks in Markdown; `nik` in terminal output) refers specifically to the CLI tool binary and its commands.
  - Keep technical identifiers (`~/.nikrun`, `--nikrun-home`, `NIKRUN_HOME`, `nikrun-fpc-sdk-*`, `nikrun.vscode`, `nikrun/github-setup-nik`, `nikrun.dev`, `nik.yaml`) in their exact lowercase technical form.
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
# Full build, test & package pipeline (outputs ZIP, release-notes.json & manifest.json to .out/)
.\build.ps1

# Fast local compile only (skips test suites) -> bin/nik[.exe]
.\build.ps1 -Profile debug -RunTests:$false

# Build optimized release binary & install into ~/.nikrun/bin
.\build.ps1 -Profile release -Install -RunTests:$false

# Run the `nik` core unit tests (tests/nik_unit_tests.pas, heaptrc leak check)
.\test-units.ps1

# Run the automated CLI & LSP end-to-end test suite directly
.\test.ps1

# CI flow: provision newest Nikrun FPC SDK from nikrun/sdk, then build, test & package release artifacts
.\prepare.ps1
.\build.ps1 -OutDir artifacts -Version "v0.1.0-build.1-channel.insider" -Profile release -Clean -RunTests
```
