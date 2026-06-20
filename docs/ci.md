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
      - uses: actions/checkout@v4
      - uses: OWNER/heimdall@v1          # repo hosting heimdall
        with:
          command: bundle --sign --notarize
          sign-identity:       ${{ secrets.MACOS_SIGN_IDENTITY }}
          macos-cert-p12:      ${{ secrets.MACOS_CERT_P12 }}
          macos-cert-password: ${{ secrets.MACOS_CERT_PASSWORD }}
          apple-id:            ${{ secrets.APPLE_ID }}
          apple-team-id:       ${{ secrets.APPLE_TEAM_ID }}
          apple-app-password:  ${{ secrets.APPLE_APP_PASSWORD }}
      - uses: actions/upload-artifact@v4
        with: { name: macos-app, path: "*.app" }
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

## Other platforms

- **Linux** — no signing step (no OS-level requirement). `heimdall bundle` is
  macOS-only today; Linux packaging (AppImage/.deb) is future work.
- **Windows** — Authenticode signing via `signtool` is stubbed (`heimdall sign`
  has the Windows code path reserved); the WebView2 backend + `.exe` packaging
  are future work.
