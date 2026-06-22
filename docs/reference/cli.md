# CLI reference

```
heimdall <command> [args]
```

| Command | What it does |
| --- | --- |
| `new <name>` | Scaffold a new project (frontend + vendored framework + CI workflow). See flags below. |
| `dev` | Start the frontend dev server + app; rebuild and relaunch on change. |
| `build` | Frontend build → embed assets → compile a release binary. |
| `bundle` | Package the app — macOS `.app`, Linux `.deb` + `.rpm`, or Windows installer `.exe` + `.zip`. |
| `sign [target]` | Code-sign an app. |
| `generate-bindings` | Run the app in schema mode and emit a typed JS client (`.js`+`.d.ts`). |
| `embed <dir> <out>` | Generate the embedded asset map (used by `build`). |
| `doctor` | Check the toolchain and platform dependencies. |
| `docs` | Serve this documentation locally in your browser. |
| `version` · `help` | Print version / usage. |

## Flags

### `new`

- `--frontend <vanilla|alpine|sveltekit>` — which frontend to scaffold (default
  `vanilla`). `vanilla` is dependency-free and Bun-served; `alpine` is the same
  but vendors [Alpine.js](https://alpinejs.dev) into `web/src/vendor/` for
  lightweight reactivity (still dependency-free + offline); `sveltekit` delegates
  to the official `sv create` (interactive) and then wires it for static
  embedding (`adapter-static`, `ssr = false`, an `index.html` SPA fallback, `dist_dir =
  web/build`).
- `--pm <bun|npm|pnpm|yarn|deno>` — package manager for the SvelteKit frontend
  (default `bun`). Controls how `sv` is run/installed and the generated
  `dev_cmd`/`build_cmd`. Ignored by the (Bun-based) vanilla frontend.
- `--add <sv-addon>` — (SvelteKit only, repeatable) a Svelte add-on passed to
  `sv create`, e.g. `--add tailwindcss=plugins:typography --add eslint`. heimdall
  adds the static adapter automatically (it must be configured during create), so
  don't pass `sveltekit-adapter` yourself. Because the adapter is forced via
  `--add`, `sv`'s interactive add-on menu is skipped — use this flag for add-ons.
- `--framework <path>` — path to the framework package to vendor (alternative to
  `HEIMDALL_HOME`).

### `build`

- `--name <bin>` — output binary name (default from `heimdall.toml`).
- `--skip-frontend` — skip the frontend build step.

### `bundle`

Packages for the host OS: a macOS `.app`, on Linux **both** a `.deb` and a `.rpm`,
or on Windows an **Inno Setup installer** (`.exe`) plus a portable `.zip` (see
[Packaging](../guide/packaging.md)).

- `--skip-build` — reuse the existing binary instead of rebuilding.
- `--sign` — code-sign the bundle (macOS `codesign`; Windows `signtool`).
- `--adhoc` — ad-hoc signature (no certificate; local testing, macOS).
- `--notarize` — notarize + staple (macOS; implies `--sign`).
- *(Linux needs no signing; `.rpm` deps are auto-detected, `.deb` deps come from
  `[bundle.linux].deb_depends`.)*
- *(Windows installer needs Inno Setup; falls back to the portable `.zip` if absent.
  `heimdall doctor` reports the build-time tooling.)*

### `sign`

- `[target]` — path to sign (defaults to the configured `.app`).
- `--adhoc` — ad-hoc signature.
- `--notarize` — notarize + staple after signing.

### `generate-bindings`

Emits a typed client module from your Odin command types: `<base>.js` (runtime,
calls `window.heimdall.invoke` under the hood) + `<base>.d.ts` (types). `dev` and
`build` run this automatically when `bindings` is set in `heimdall.toml`; `new`
generates it once.

- `--out <base>` — output base path (default: `bindings` from `heimdall.toml`, else
  `web/src/heimdall.gen`). A trailing `.js`/`.ts`/`.d.ts` is stripped.
- `-- <odin flags>` — pass extra flags to the Odin build (e.g. `-collection:…`).

```js
import { greeting, on } from "./heimdall.gen.js"
await greeting.greet({ name: "Jake" })
```

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
- `HEIMDALL_SCHEMA` — schema-dump mode (used by `generate-bindings`).
