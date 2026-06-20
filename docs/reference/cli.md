# CLI reference

```
heimdall <command> [args]
```

| Command | What it does |
| --- | --- |
| `new <name>` | Scaffold a new project (frontend + vendored framework + CI workflow). |
| `dev` | Start the frontend dev server + app; rebuild and relaunch on change. |
| `build` | Frontend build → embed assets → compile a release binary. |
| `bundle` | Build + assemble a macOS `.app`. |
| `sign [target]` | Code-sign an app. |
| `generate-bindings` | Run the app in schema mode and emit a typed `.d.ts`. |
| `embed <dir> <out>` | Generate the embedded asset map (used by `build`). |
| `doctor` | Check the toolchain and platform dependencies. |
| `docs` | Serve this documentation locally in your browser. |
| `version` · `help` | Print version / usage. |

## Flags

### `dev` · `build` · `bundle`

- `--webview` — use the cross-platform webview/webview backend. On macOS the
  native WKWebView backend is the default; this opts out of it.

### `build`

- `--name <bin>` — output binary name (default from `heimdall.toml`).
- `--skip-frontend` — skip the frontend build step.

### `bundle`

- `--skip-build` — reuse the existing binary instead of rebuilding.
- `--sign` — code-sign the bundle.
- `--adhoc` — ad-hoc signature (no certificate; local testing).
- `--notarize` — notarize + staple (macOS; implies `--sign`).

### `sign`

- `[target]` — path to sign (defaults to the configured `.app`).
- `--adhoc` — ad-hoc signature.
- `--notarize` — notarize + staple after signing.

### `generate-bindings`

- `--out <path>` — output `.d.ts` (default `web/bindings.d.ts`).
- `-- <odin flags>` — pass extra flags to the Odin build (e.g. `-collection:…`).

### `embed`

- `--import <path>` — framework import path used in the generated file (default
  `heimdall`).

### `docs`

Serves the documentation site locally (the live VitePress dev server by default).
Finds the docs under `./docs` or `$HEIMDALL_HOME/docs`; if neither exists, it opens
the hosted docs instead. Requires [Bun](https://bun.sh).

- `--build` — build the static site and preview it (instead of the dev server).
- `--port <n>` — port to serve on.
- `--no-open` — don't open a browser automatically.

## Environment variables

| Variable | Used by | Purpose |
| --- | --- | --- |
| `HEIMDALL_SIGN_IDENTITY` | `sign`, `bundle --sign` | codesign identity (overrides `[sign].identity`) |
| `HEIMDALL_NOTARY_PROFILE` | `--notarize` | notarytool keychain-profile name |
| `HEIMDALL_APPLE_ID` / `HEIMDALL_TEAM_ID` / `HEIMDALL_APP_PASSWORD` | `--notarize` | notarization creds (alternative to a profile) |
| `HEIMDALL_HOME` | `new` | locates the framework to vendor (alternative to `--framework`) |

## Build defines (Odin)

Passed as `-define:NAME=true` when building an app directly:

- `HEIMDALL_DEV` — point the webview at `dev_url` (HMR) instead of embedded assets.
- `HEIMDALL_WEBVIEW` — force the webview/webview backend (native is the default on macOS).
- `HEIMDALL_SCHEMA` — schema-dump mode (used by `generate-bindings`).
