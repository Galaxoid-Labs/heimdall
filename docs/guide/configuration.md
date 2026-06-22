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

## Graphics (WebGL / WebGPU)

These are runtime settings on `App_Config` (in `main.odin`), not `heimdall.toml`
keys — Heimdall just uses each platform's system webview, so what's available
depends on the engine.

- **WebGL (1 and 2)** is always on — no setting needed. It's mature in WKWebView,
  WebKitGTK, and WebView2. (It still needs a working GPU/GL driver on the machine,
  which matters most on Linux and in headless/VM environments.)
- **WebGPU** is **opt-in** and engine-dependent. Set `webgpu = true`:

```odin
app, _ := hd.create(hd.App_Config{
    title  = "My App",
    webgpu = true,   // enable WebGPU where the system webview supports it
})
```

What `webgpu = true` does per platform:

| Platform | Effect |
| --- | --- |
| **Windows** (WebView2 / Chromium) | passes `--enable-unsafe-webgpu`; works on a recent Evergreen runtime |
| **macOS** (WKWebView) | flips the WebKit "WebGPU" feature flag; recent WebKit (Safari 26+) already enables it by default |
| **Linux** (WebKitGTK) | enables the experimental "WebGPU" feature if the installed WebKitGTK build exposes it — otherwise a no-op |

It's a safe flag to set, but don't treat WebGPU as a dependable cross-platform
baseline yet (Windows is solid; macOS depends on the OS version; Linux is
experimental). Feature-detect with `navigator.gpu` and keep a WebGL fallback —
which most WebGPU libraries do anyway.

## Content Security Policy (CSP)

Heimdall sets **no CSP of its own** — your frontend owns it (a
`<meta http-equiv="Content-Security-Policy">` tag, or your bundler). You can ship
a strict policy without breaking the bridge.

**The bridge is CSP-safe.** A tight CSP (even `script-src 'self'`, no inline)
won't break `invoke`/`on`:

- the JS shim is **injected by the native host** (not a page script), so it runs
  outside `script-src` enforcement;
- Odin→JS replies/events use **host-initiated evaluation** (like the devtools
  console), which the page CSP doesn't gate;
- the bridge talks over `postMessage`, not `fetch`, so `connect-src` doesn't
  apply to it.

**What your CSP still has to allow** (your app's own resources):

- **Embedded assets** load from `app://localhost/` in prod — `default-src 'self'`
  covers them (same origin); name the `app:` scheme explicitly only if you
  hardcode it.
- **WebAssembly** (common in WebGPU/graphics stacks) needs
  `script-src 'wasm-unsafe-eval'` under a strict policy. WGSL shaders themselves
  aren't CSP-gated. This is the most common gotcha.
- **Dev mode** is looser than prod: the bundler serves over
  `http://localhost:<port>` with HMR websockets and often inline scripts. Keep a
  relaxed CSP for `heimdall dev` (e.g. allow `ws://localhost:*` in `connect-src`)
  and a strict one for release.

**Secure context.** `navigator.gpu`, `crypto.subtle`, and service workers require
a [secure context](https://developer.mozilla.org/docs/Web/Security/Secure_Contexts).
Heimdall registers `app://` as **secure + CORS-enabled**, so your embedded app is
a secure origin and `fetch()` to `app://` won't trip CORS.

## Secrets

Secrets never go in the file. The signing identity and notarization credentials
are read from environment variables — handy for CI:

- `HEIMDALL_SIGN_IDENTITY`
- `HEIMDALL_NOTARY_PROFILE`, or `HEIMDALL_APPLE_ID` + `HEIMDALL_TEAM_ID` +
  `HEIMDALL_APP_PASSWORD`

See [Packaging & Signing](./packaging.md) and [CI](../ci.md).
