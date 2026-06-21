# Configuration

`heimdall.toml` is optional and kept small. Project settings are top-level;
packaging and signing live under `[bundle]` / `[sign]`, with **per-platform
overrides** so you only repeat what actually differs between platforms.

```toml
name    = "myapp"
web_dir = "web"
dist_dir  = "web/dist"                 # frontend build output (embedded)
dev_url = "http://localhost:5173"
dev_cmd   = "bun run dev"
build_cmd = "bun run build"
bindings  = "web/src/heimdall.gen"     # typed JS client base; dev/build regenerate it

[bundle]                              # common to every platform
identifier   = "com.example.myapp"    # required to bundle (reverse-DNS)
version      = "1.0.0"
build        = "1"
display_name = "My App"
icon         = "icon.png"             # .png is auto-converted to .icns
schemes      = "myapp"                # deep-link URL scheme(s); comma-separate for multiple

[bundle.macos]                        # only what's macOS-specific
min_macos = "12.0"
category  = "public.app-category.productivity"

[sign.macos]
identity       = "Developer ID Application: Name (TEAMID)"
notary_profile = "myapp-notary"
```

## Common vs. per-platform

A setting resolves **platform-first, then common**:

- On macOS, `[bundle.macos]` wins over `[bundle]`.
- Anything only in `[bundle]` applies everywhere.
- Sections for other platforms (`[bundle.windows]`, `[bundle.linux]`) are ignored
  on the current host.

A flat `[bundle]` / `[sign]` with no platform sections is treated entirely as
common, so simple projects stay simple.

## Keys

**Top-level** — `name`, `web_dir`, `dist_dir`, `dev_cmd`, `build_cmd`, `dev_url`,
`bindings` (typed-client base path; omit to disable auto-generation).

**`[bundle]`** — `identifier` (required), `version`, `build`, `display_name`,
`icon`, `schemes` (deep-link URL schemes — see [Deep linking](./deep-linking.md)),
plus `[bundle.macos]` `min_macos` / `category`.

**`[sign]`** — `identity`, `entitlements`, `notary_profile` (typically under
`[sign.macos]`).

## Secrets

Secrets never go in the file. The signing identity and notarization credentials
are read from environment variables — handy for CI:

- `HEIMDALL_SIGN_IDENTITY`
- `HEIMDALL_NOTARY_PROFILE`, or `HEIMDALL_APPLE_ID` + `HEIMDALL_TEAM_ID` +
  `HEIMDALL_APP_PASSWORD`

See [Packaging & Signing](./packaging.md) and [CI](../ci.md).
