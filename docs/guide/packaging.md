# Packaging & Signing

## Build a binary

```sh
heimdall build              # frontend build → embed assets → compile -> ./myapp
heimdall build --webview    # opt into the webview/webview backend (native is default on macOS)
```

The result is a single executable with your frontend embedded.

## Bundle a macOS `.app`

```sh
heimdall bundle             # -> ./MyApp.app
```

Requires `[bundle].identifier` in [`heimdall.toml`](./configuration.md). The
bundle gets an `Info.plist`, the executable, a `PkgInfo`, and (if you set
`[bundle].icon`) an `AppIcon.icns` — a `.png` is converted automatically via
`sips` / `iconutil`.

## Code signing

Signing dispatches per platform: macOS uses `codesign` + notarization; Windows
uses `signtool` (stubbed for now); **Linux needs no signing**.

```sh
heimdall bundle --adhoc            # ad-hoc signature — local testing, no certificate
heimdall bundle --sign             # Developer ID signing (hardened runtime)
heimdall bundle --sign --notarize  # + Apple notarization & stapling
heimdall sign [target]             # sign an existing app
```

The identity comes from `[sign].identity` or `HEIMDALL_SIGN_IDENTITY`. Ad-hoc
signing needs no certificate and is fine for local runs, but other Macs require a
Developer ID + notarization.

### Notarization credentials

Use a stored notarytool profile, or environment variables (CI-friendly):

```sh
# one-time: store a profile in the keychain
xcrun notarytool store-credentials myapp-notary \
  --apple-id "you@example.com" --team-id "TEAMID" --password "app-specific-pw"
```

```
HEIMDALL_NOTARY_PROFILE=myapp-notary
# or:
HEIMDALL_APPLE_ID / HEIMDALL_TEAM_ID / HEIMDALL_APP_PASSWORD
```

## Automating releases

`heimdall new` scaffolds `.github/workflows/release.yml` that uses a reusable
composite action to build, bundle, sign, and notarize on a tag push. See
[CI / GitHub Actions](../ci.md).
