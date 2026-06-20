# Packaging & Signing

## Build a binary

```sh
heimdall build              # frontend build → embed assets → compile -> ./myapp
heimdall build --webview    # opt into the webview/webview backend (native is default on macOS & Linux)
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

## Bundle for Linux (`.deb` + `.rpm`)

On Linux, `heimdall bundle` emits **both** a Debian `.deb` and an RPM `.rpm`:

```sh
heimdall bundle             # -> ./myapp_1.0.0_amd64.deb  and  ./myapp-1.0.0-1.x86_64.rpm
```

Each package installs the executable to `/usr/bin`, a `.desktop` entry to
`/usr/share/applications`, and (if `[bundle].icon` is a `.png`) an icon under
`hicolor/256x256`. Tooling: `dpkg-deb` for the `.deb` (built with
`--root-owner-group`, no `fakeroot` needed) and `rpmbuild` for the `.rpm`. If only
one is installed, you get that package and a note about the other.

**Dependencies.** The `.rpm`'s `Requires` are **auto-detected** from the binary's
linked libraries (so the GTK4/WebKit runtime is pulled in automatically). The
`.deb`'s `Depends` defaults to `libwebkitgtk-6.0-4, libadwaita-1-0, libgtk-4-1`
— override with `[bundle.linux].deb_depends` if your target names them
differently. (End users get the webview runtime via their package manager; see
[platform notes](../platform_notes.md).)

**Metadata** comes from `heimdall.toml` (all optional, with `[bundle.linux]`
overrides):

```toml
[bundle]
identifier  = "com.example.myapp"   # used as the .desktop / icon id
version     = "1.0.0"
summary     = "A short one-liner"
description = "A longer description."
maintainer  = "Your Name <you@example.com>"
license     = "MIT"
homepage    = "https://example.com"
icon        = "icon.png"            # .png for Linux

[bundle.linux]
category    = "Utility;Development;" # freedesktop Categories for the .desktop
# deb_depends = "libwebkitgtk-6.0-4, libadwaita-1-0, libgtk-4-1"
```

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
