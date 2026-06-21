# Packaging & CI

## Config layout: common vs. per-platform

`heimdall.toml` splits packaging settings into a **common** section and optional
**per-platform overrides**, so you only repeat what's actually platform-specific:

```toml
[bundle]                       # common to every platform
identifier   = "com.acme.app"
version      = "1.0.0"
display_name = "Acme"
icon         = "icon.png"      # common icon

[bundle.macos]                 # overrides on macOS only
min_macos    = "12.0"
category     = "public.app-category.productivity"
icon         = "icon.icns"     # macOS-specific icon (else the common one is used)

# [bundle.windows]  /  [bundle.linux]

[sign.macos]
identity       = "Developer ID Application: Acme (TEAMID)"
notary_profile = "acme-notary"

# [sign.windows]
# identity = "Acme, Inc."      # certificate subject
```

A setting resolves **platform-first, then common**: on macOS, `[bundle.macos]`
wins over `[bundle]`; anything only in `[bundle]` applies everywhere. Sections for
other platforms are ignored on the current host. (A flat `[bundle]`/`[sign]` with
no platform sections still works — it's all "common".)

---

# CI / GitHub Actions

Heimdall ships a reusable composite action (`action.yml` at the repo root) that
installs the toolchain, builds the heimdall CLI, and runs `heimdall build` /
`bundle` / `sign` / `notarize` for you — so a release workflow is a few lines.

## Use the action

The scaffolded workflow has one job per platform — macOS, Linux, and Windows —
each calling the action on its native runner:

```yaml
# .github/workflows/release.yml   (scaffolded by `heimdall new`)
name: release
on:
  push:
    tags: ["v*"]
jobs:
  macos:
    runs-on: macos-14
    steps:
      - uses: actions/checkout@v7
      - uses: OWNER/heimdall@v1          # repo hosting heimdall
        with:
          command: bundle --sign --notarize
          sign-identity:       ${{ secrets.MACOS_SIGN_IDENTITY }}
          macos-cert-p12:      ${{ secrets.MACOS_CERT_P12 }}
          macos-cert-password: ${{ secrets.MACOS_CERT_PASSWORD }}
          apple-id:            ${{ secrets.APPLE_ID }}
          apple-team-id:       ${{ secrets.APPLE_TEAM_ID }}
          apple-app-password:  ${{ secrets.APPLE_APP_PASSWORD }}
      - uses: actions/upload-artifact@v7
        with: { name: app-macos, path: "*.app" }

  linux:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
      - uses: OWNER/heimdall@v1          # auto-installs the GTK4/WebKitGTK deps on Linux
        with: { command: bundle }        # no signing on Linux
      - uses: actions/upload-artifact@v7
        with: { name: app-linux, path: "*.deb\n*.rpm" }

  windows:
    runs-on: windows-latest
    steps:
      - uses: actions/checkout@v7
      - uses: OWNER/heimdall@v1
        with: { command: bundle }
      - uses: actions/upload-artifact@v7
        with: { name: app-windows, path: "dist/windows/*.exe\ndist/windows/*.zip" }
```

Unsigned / quick CI: drop the signing inputs, or use `command: bundle --adhoc`
(no certificate needed — fine for internal builds, not for distribution).

### Action inputs

| input | purpose |
| --- | --- |
| `command` | heimdall subcommand + args (default `bundle`) |
| `working-directory` | app directory (default `.`) |
| `odin-release` | Odin release tag to install |
| `sign-identity` | `Developer ID Application: …` → `HEIMDALL_SIGN_IDENTITY` |
| `macos-cert-p12` / `macos-cert-password` | base64 `.p12` + its password (imported into a temp keychain) |
| `apple-id` / `apple-team-id` / `apple-app-password` | notarization creds (stored as a notarytool profile) |
| `notary-profile` | profile name (default `heimdall-notary`) → `HEIMDALL_NOTARY_PROFILE` |

Each step is skipped when its inputs are empty, so the same action covers
unsigned, ad-hoc, signed, and signed+notarized builds.

## Required secrets (signed release)

| secret | how to get it |
| --- | --- |
| `MACOS_SIGN_IDENTITY` | the cert common name, e.g. `Developer ID Application: Jane Dev (TEAMID)` |
| `MACOS_CERT_P12` | export your Developer ID cert+key as `.p12`, then `base64 -i cert.p12 \| pbcopy` |
| `MACOS_CERT_PASSWORD` | the password you set on the `.p12` |
| `APPLE_ID` | your Apple ID email |
| `APPLE_TEAM_ID` | your Developer Team ID |
| `APPLE_APP_PASSWORD` | an app-specific password (appleid.apple.com → Sign-In and Security) |

## Doing it without the action

The action just wraps the standard steps; any CI can do them directly:

1. install Odin + bun, build the heimdall CLI,
2. `heimdall bundle` (frontend build → embed → compile → `.app`),
3. import the signing cert into a temp keychain (`security create-keychain` /
   `import` / `set-key-partition-list`),
4. `heimdall sign --notarize` (or `heimdall bundle --sign --notarize`).

See `action.yml` for the exact commands.

## Per-platform notes

The scaffolded workflow already runs all three; what differs per platform:

- **macOS** — signed + notarized when the secrets above are set (otherwise drop
  those inputs for an unsigned/ad-hoc build). Output: `.app`.
- **Linux** — no signing (no OS-level requirement). The action installs the
  GTK4/WebKitGTK dev packages on the runner automatically; `heimdall bundle`
  produces a `.deb` and an `.rpm` (see [Packaging](./guide/packaging.md)).
- **Windows** — `heimdall bundle` produces an Inno Setup installer `.exe` plus a
  portable `.zip` (under `dist/windows/`). Authenticode signing via `signtool` is
  supported by `heimdall sign`; add the cert as a secret and a sign step if you
  distribute signed installers.

---

## Releasing heimdall itself

This is about shipping **heimdall** (the framework/CLI), not your app — relevant
if you maintain a fork.

The installers (`install.sh` / `install.ps1`) download prebuilt assets from a
GitHub Release: a CLI binary per platform (`heimdall-<os>-<arch>[.exe]`), the
framework source (`heimdall-framework.tar.gz`), and a `SHA256SUMS` file. Those are
produced by `.github/workflows/release.yml` on a tag push:

```sh
git tag v0.1.0
git push --tags        # builds the CLI natively per arch, tars the framework,
                       # writes SHA256SUMS, attaches all to the release
```

Targets (each built on a native runner — Odin can't link cross-compiled
binaries): **macOS arm64**, **Linux x86_64**, **Linux arm64**, **Windows x86_64**.
Windows arm64 is not produced — `windows_arm64` isn't an Odin target. Intel macOS
isn't built either (add a `macos-13` / `darwin_amd64` matrix row if you need it).
Build straight to the asset name (`-out:heimdall-<os>-<arch>`), never `-out:heimdall`
— that collides with the `heimdall/` framework directory.

The installers verify each download against `SHA256SUMS` before installing and
abort on a mismatch (`HEIMDALL_SKIP_VERIFY=1` opts out — not recommended).

Until a tagged release exists, the `curl … | sh` one-liners have nothing to fetch.
For local/mirror testing, point an installer at a base URL holding the assets and
a matching `SHA256SUMS` (or set `HEIMDALL_SKIP_VERIFY=1`):

```sh
HEIMDALL_BASE_URL="file:///path/to/assets" HEIMDALL_YES=1 sh install.sh
```

## Publishing the docs site

The docs deploy via `.github/workflows/docs.yml` (VitePress → GitHub Pages). One
required setting: **repo Settings → Pages → Source → "GitHub Actions"**. If Source
is left on "Deploy from a branch", GitHub serves the raw `docs/` markdown through
Jekyll and the site renders blank. The `base` in `docs/.vitepress/config.ts` must
match the repo path (`/heimdall/` for `github.io/heimdall/`).
